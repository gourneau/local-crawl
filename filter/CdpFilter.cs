using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

// A small Chrome DevTools Protocol proxy between crw-server and Chrome.
//
// It passes every message through untouched, except the two things that make crw's
// browser look *less* like a real one:
//   - crw's injected "stealth" script, which fakes a Mac GPU and patches navigator
//     properties in ways fingerprinting scripts detect;
//   - crw's User-Agent override, which blanks Chrome's client hints.
// Chrome then presents its own, genuine fingerprint. Those commands get a
// success reply so crw carries on as normal.
//
// Usage: cdp-filter.exe --listen 9223 --upstream 9224 [--log path] [--drop Method1,Method2]
//   --drop  extra DevTools commands to answer with an empty success instead of
//           forwarding, e.g. Runtime.enable (a well-known automation giveaway).
static class CdpFilter
{
    const string StealthMarker = "Hide navigator.webdriver";
    const string SkippedScriptId = "crw-skipped";

    static int _listenPort = 9223;
    static int _upstreamPort = 9224;
    static string _logPath;
    static readonly HashSet<string> DropMethods = new HashSet<string> { "Network.setUserAgentOverride" };
    static readonly object LogLock = new object();
    static readonly Dictionary<string, int> MethodCounts = new Dictionary<string, int>();
    static readonly Regex MethodPattern = new Regex("\"method\"\\s*:\\s*\"([^\"]+)\"");

    static int Main(string[] args)
    {
        for (int i = 0; i + 1 < args.Length; i += 2)
        {
            if (args[i] == "--listen") _listenPort = int.Parse(args[i + 1], CultureInfo.InvariantCulture);
            else if (args[i] == "--upstream") _upstreamPort = int.Parse(args[i + 1], CultureInfo.InvariantCulture);
            else if (args[i] == "--log") _logPath = args[i + 1];
            else if (args[i] == "--drop")
            {
                foreach (string method in args[i + 1].Split(','))
                {
                    if (method.Trim().Length > 0) DropMethods.Add(method.Trim());
                }
            }
        }
        Log("answering without forwarding: " + string.Join(", ", DropMethods) + ", and crw's stealth script");

        TcpListener listener = new TcpListener(IPAddress.Loopback, _listenPort);
        listener.Start();
        Log(string.Format("listening on 127.0.0.1:{0}, forwarding to Chrome on 127.0.0.1:{1}", _listenPort, _upstreamPort));
        while (true)
        {
            TcpClient client = listener.AcceptTcpClient();
            Thread worker = new Thread(delegate () { HandleConnection(client); });
            worker.IsBackground = true;
            worker.Start();
        }
    }

    static void HandleConnection(TcpClient client)
    {
        TcpClient upstream = new TcpClient();
        try
        {
            client.NoDelay = true;
            upstream.NoDelay = true;
            NetworkStream clientStream = client.GetStream();
            byte[] head, extra;
            if (!ReadHttpHead(clientStream, out head, out extra)) return;

            upstream.Connect(IPAddress.Loopback, _upstreamPort);
            NetworkStream upstreamStream = upstream.GetStream();
            upstreamStream.Write(head, 0, head.Length);
            if (extra.Length > 0) upstreamStream.Write(extra, 0, extra.Length);

            if (Encoding.ASCII.GetString(head).IndexOf("upgrade: websocket", StringComparison.OrdinalIgnoreCase) < 0)
            {
                // Plain HTTP (/json/version and friends): copy both ways until either side closes.
                Thread toUpstream = new Thread(delegate () { Copy(clientStream, upstreamStream); });
                toUpstream.IsBackground = true;
                toUpstream.Start();
                Copy(upstreamStream, clientStream);
                return;
            }

            byte[] responseHead, responseExtra;
            if (!ReadHttpHead(upstreamStream, out responseHead, out responseExtra)) return;
            clientStream.Write(responseHead, 0, responseHead.Length);

            object clientWriteLock = new object();
            Thread fromChrome = new Thread(delegate ()
            {
                PumpFromChrome(new FrameReader(upstreamStream, responseExtra), clientStream, clientWriteLock);
                client.Close();
            });
            fromChrome.IsBackground = true;
            fromChrome.Start();
            PumpFromCrw(new FrameReader(clientStream, extra), upstreamStream, clientStream, clientWriteLock);
        }
        catch (Exception ex)
        {
            if (!(ex is IOException) && !(ex is ObjectDisposedException)) Log("connection error: " + ex.Message);
        }
        finally
        {
            client.Close();
            upstream.Close();
        }
    }

    // Chrome -> crw: forward whole frames, so filter replies never land mid-frame.
    static void PumpFromChrome(FrameReader reader, Stream toClient, object writeLock)
    {
        try
        {
            Frame frame;
            while ((frame = reader.Next()) != null)
            {
                lock (writeLock) { toClient.Write(frame.Raw, 0, frame.Raw.Length); }
                if (frame.Opcode == 8) return;
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    // crw -> Chrome: inspect each complete text message and either forward it or answer it here.
    static void PumpFromCrw(FrameReader reader, Stream toChrome, Stream toClient, object clientWriteLock)
    {
        List<Frame> parts = new List<Frame>();
        Frame frame;
        while ((frame = reader.Next()) != null)
        {
            if (frame.Opcode >= 8)
            {
                toChrome.Write(frame.Raw, 0, frame.Raw.Length);
                if (frame.Opcode == 8) return;
                continue;
            }
            parts.Add(frame);
            if (!frame.Fin) continue;

            string reply = null;
            if (parts[0].Opcode == 1) reply = Filter(Encoding.UTF8.GetString(Concat(parts)));
            if (reply != null)
            {
                byte[] replyFrame = TextFrame(reply);
                lock (clientWriteLock) { toClient.Write(replyFrame, 0, replyFrame.Length); }
            }
            else
            {
                foreach (Frame part in parts) toChrome.Write(part.Raw, 0, part.Raw.Length);
            }
            parts.Clear();
        }
    }

    // Returns a JSON reply for commands we answer ourselves, or null to forward the message.
    static string Filter(string message)
    {
        Match match = MethodPattern.Match(message);
        if (!match.Success) return null;
        string method = match.Groups[1].Value;
        CountMethod(method);
        if (method != "Page.addScriptToEvaluateOnNewDocument" &&
            method != "Page.removeScriptToEvaluateOnNewDocument" &&
            !DropMethods.Contains(method))
        {
            return null;
        }

        JavaScriptSerializer json = new JavaScriptSerializer();
        json.MaxJsonLength = int.MaxValue;
        Dictionary<string, object> command = json.DeserializeObject(message) as Dictionary<string, object>;
        if (command == null || !command.ContainsKey("id") || !command.ContainsKey("method")) return null;
        method = command["method"] as string;
        Dictionary<string, object> args = command.ContainsKey("params") ? command["params"] as Dictionary<string, object> : null;

        string result = null;
        if (method == "Page.addScriptToEvaluateOnNewDocument")
        {
            string source = args != null && args.ContainsKey("source") ? args["source"] as string : null;
            if (source != null && source.Contains(StealthMarker)) result = "{\"identifier\":\"" + SkippedScriptId + "\"}";
        }
        else if (method == "Page.removeScriptToEvaluateOnNewDocument")
        {
            string id = args != null && args.ContainsKey("identifier") ? args["identifier"] as string : null;
            if (id == SkippedScriptId) result = "{}";
        }
        else if (method != null && DropMethods.Contains(method))
        {
            result = "{}";
        }
        if (result == null) return null;

        CountMethod("(dropped) " + method);
        StringBuilder reply = new StringBuilder("{\"id\":");
        reply.Append(Convert.ToString(command["id"], CultureInfo.InvariantCulture));
        reply.Append(",\"result\":").Append(result);
        if (command.ContainsKey("sessionId")) reply.Append(",\"sessionId\":").Append(json.Serialize(command["sessionId"]));
        return reply.Append('}').ToString();
    }

    // Logs each command name the first time it's seen, so you can audit what crw sends.
    static void CountMethod(string method)
    {
        bool first;
        lock (MethodCounts)
        {
            int count;
            MethodCounts.TryGetValue(method, out count);
            MethodCounts[method] = count + 1;
            first = count == 0;
        }
        if (first) Log("first seen: " + method);
    }

    // --- WebSocket and HTTP plumbing ------------------------------------------------

    sealed class Frame
    {
        public byte[] Raw;      // the frame exactly as received, for forwarding
        public bool Fin;
        public int Opcode;
        public byte[] Payload;  // unmasked
    }

    sealed class FrameReader
    {
        readonly Stream _stream;
        readonly byte[] _pending;
        int _pendingPos;

        public FrameReader(Stream stream, byte[] alreadyRead)
        {
            _stream = stream;
            _pending = alreadyRead;
        }

        bool ReadExact(byte[] buffer, int offset, int count)
        {
            while (count > 0)
            {
                int n;
                if (_pending != null && _pendingPos < _pending.Length)
                {
                    n = Math.Min(count, _pending.Length - _pendingPos);
                    Buffer.BlockCopy(_pending, _pendingPos, buffer, offset, n);
                    _pendingPos += n;
                }
                else
                {
                    n = _stream.Read(buffer, offset, count);
                    if (n <= 0) return false;
                }
                offset += n;
                count -= n;
            }
            return true;
        }

        public Frame Next()
        {
            byte[] start = new byte[2];
            if (!ReadExact(start, 0, 2)) return null;
            bool masked = (start[1] & 0x80) != 0;
            long length = start[1] & 0x7F;
            byte[] extended = new byte[length == 126 ? 2 : length == 127 ? 8 : 0];
            if (extended.Length > 0)
            {
                if (!ReadExact(extended, 0, extended.Length)) return null;
                length = 0;
                foreach (byte b in extended) length = (length << 8) | b;
            }
            if (length > int.MaxValue) throw new IOException("frame too large");
            byte[] mask = new byte[masked ? 4 : 0];
            if (masked && !ReadExact(mask, 0, 4)) return null;
            byte[] payload = new byte[length];
            if (!ReadExact(payload, 0, payload.Length)) return null;

            byte[] raw = new byte[2 + extended.Length + mask.Length + payload.Length];
            Buffer.BlockCopy(start, 0, raw, 0, 2);
            Buffer.BlockCopy(extended, 0, raw, 2, extended.Length);
            Buffer.BlockCopy(mask, 0, raw, 2 + extended.Length, mask.Length);
            Buffer.BlockCopy(payload, 0, raw, 2 + extended.Length + mask.Length, payload.Length);
            if (masked)
            {
                for (int i = 0; i < payload.Length; i++) payload[i] ^= mask[i % 4];
            }
            Frame frame = new Frame();
            frame.Raw = raw;
            frame.Fin = (start[0] & 0x80) != 0;
            frame.Opcode = start[0] & 0x0F;
            frame.Payload = payload;
            return frame;
        }
    }

    // An unmasked, unfragmented server-to-client text frame.
    static byte[] TextFrame(string text)
    {
        byte[] payload = Encoding.UTF8.GetBytes(text);
        byte[] header;
        if (payload.Length < 126)
        {
            header = new byte[] { 0x81, (byte)payload.Length };
        }
        else if (payload.Length <= 0xFFFF)
        {
            header = new byte[] { 0x81, 126, (byte)(payload.Length >> 8), (byte)payload.Length };
        }
        else
        {
            header = new byte[10];
            header[0] = 0x81;
            header[1] = 127;
            long len = payload.Length;
            for (int i = 9; i >= 2; i--) { header[i] = (byte)len; len >>= 8; }
        }
        byte[] frame = new byte[header.Length + payload.Length];
        Buffer.BlockCopy(header, 0, frame, 0, header.Length);
        Buffer.BlockCopy(payload, 0, frame, header.Length, payload.Length);
        return frame;
    }

    static byte[] Concat(List<Frame> parts)
    {
        if (parts.Count == 1) return parts[0].Payload;
        MemoryStream all = new MemoryStream();
        foreach (Frame part in parts) all.Write(part.Payload, 0, part.Payload.Length);
        return all.ToArray();
    }

    // Reads an HTTP header block (through the blank line). Anything read past it is returned in `extra`.
    static bool ReadHttpHead(Stream stream, out byte[] head, out byte[] extra)
    {
        MemoryStream buffer = new MemoryStream();
        byte[] chunk = new byte[4096];
        head = extra = new byte[0];
        while (buffer.Length < 65536)
        {
            int n = stream.Read(chunk, 0, chunk.Length);
            if (n <= 0) return false;
            buffer.Write(chunk, 0, n);
            byte[] data = buffer.ToArray();
            for (int i = 3; i < data.Length; i++)
            {
                if (data[i - 3] == '\r' && data[i - 2] == '\n' && data[i - 1] == '\r' && data[i] == '\n')
                {
                    head = new byte[i + 1];
                    Buffer.BlockCopy(data, 0, head, 0, i + 1);
                    extra = new byte[data.Length - i - 1];
                    Buffer.BlockCopy(data, i + 1, extra, 0, extra.Length);
                    return true;
                }
            }
        }
        return false;
    }

    static void Copy(Stream from, Stream to)
    {
        byte[] buffer = new byte[65536];
        try
        {
            int n;
            while ((n = from.Read(buffer, 0, buffer.Length)) > 0) to.Write(buffer, 0, n);
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    static void Log(string message)
    {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + message + Environment.NewLine;
        lock (LogLock)
        {
            try
            {
                if (_logPath != null) File.AppendAllText(_logPath, line);
            }
            catch (IOException) { }
        }
    }
}
