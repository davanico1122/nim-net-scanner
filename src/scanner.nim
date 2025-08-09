# scanner.nim
# Simple multi-threaded port scanner + banner grabbing + logging
# Usage:
#   nim c -d:release --out:scanner.exe scanner.nim
#   ./scanner <target> <startPort> <endPort> [threads]
#
# Notes:
# - Use in isolated lab only.
# - Banner grabbing: read whatever server sends on connect.
# - For HTTP we try a simple GET if no banner received.

import os, strutils, sequtils, locks, threads, net, times, streams

# --------------------
# Configurable params
# --------------------
const
  DEFAULT_THREADS = 50
  CONNECT_TIMEOUT_MS = 800  # per-connection timeout
  BANNER_READ_BYTES = 1024

# --------------------
# Shared queue & locking
# --------------------
var
  portsQueue: seq[int] = @[]
  qLock = initLock()
  logLock = initLock()

proc initQueue(startP, endP: int) =
  portsQueue = @[]
  for p in startP..endP:
    portsQueue.add(p)

proc popPort(): int =
  qLock.lock()
  let res =
    if portsQueue.len == 0: 0
    else:
      let v = portsQueue[0]
      portsQueue.delete(0)
      v
  qLock.unlock()
  return res

# --------------------
# Logging helper
# --------------------
proc logLine(path: string, s: string) =
  logLock.lock()
  try:
    var f = open(path, fmAppend)
    f.writeLine($now() & " | " & s)
    f.close()
  except:
    # ignore logging errors
    discard
  logLock.unlock()

# --------------------
# Banner grabbing & port scanning
# --------------------
proc tryConnectAndGrab(target: string, port: int, out logfile: string): bool =
  ## Returns true if port open. Attempts to read banner.
  var sock: Socket
  try
    sock = newSocket()
    sock.setBlocking(false)
    # set a deadline (fallback)
    let deadline = epochTime() + CONNECT_TIMEOUT_MS.toTimeInterval() / 1000.0
    # attempt connect (blocking connect with timeout loop)
    var connected = false
    sock.setBlocking(true)
    try:
      sock.connect(target, Port(port))
      connected = true
    except OSError:
      # not connected
      connected = false

    if not connected:
      sock.close()
      return false

    # Connected -> try to read whatever is available
    var banner = ""
    try:
      # set short read timeout
      sock.setBlocking(false)
      var buf = newString(BANNER_READ_BYTES)
      # try a short sleep to allow immediate banners to arrive
      sleep(10)
      var n = sock.recv(buf)
      if n > 0:
        banner = buf[0..(n-1)].strip()
      else:
        banner = ""
      # If no banner and port is HTTP-ish, send a simple GET
      if banner.len == 0 and (port == 80 or port == 8080 or port == 8000):
        let req = "GET / HTTP/1.0\r\nHost: " & target & "\r\n\r\n"
        sock.send(req)
        sleep(20)
        var buf2 = newString(BANNER_READ_BYTES * 2)
        let n2 = sock.recv(buf2)
        if n2 > 0:
          banner = buf2[0..(n2-1)].strip()
      # close socket
      sock.close()
    except OSError:
      # on read errors, still treat as open
      try:
        sock.close()
      except:
        discard
    # Log result
    let outLine = "OPEN - " & target & ":" & $port & " - banner: " & (if banner.len>0: banner else: "<no-banner>")
    echo outLine
    logLine(logfile, outLine)
    return true
  except OSError:
    # connection failed
    try:
      sock.close()
    except:
      discard
    return false

# --------------------
# Worker thread
# --------------------
proc worker(target: string, logfile: string) =
  while true:
    let p = popPort()
    if p == 0:
      break
    # attempt connect; ignore result if closed
    discard tryConnectAndGrab(target, p, logfile)

# --------------------
# Main
# --------------------
when isMainModule:
  if paramCount() < 3:
    echo "Usage: scanner <target> <startPort> <endPort> [threads]"
    quit(1)

  let target = paramStr(1)
  let startP = parseInt(paramStr(2))
  let endP = parseInt(paramStr(3))
  var nThreads = if paramCount() >= 4: parseInt(paramStr(4)) else: DEFAULT_THREADS
  if nThreads < 1: nThreads = 1
  if startP < 1: startP = 1
  if endP < startP: (echo "endPort must be >= startPort"; quit(1))

  initQueue(startP, endP)
  let logfile = joinPath(".", "out", "scan-results.log")
  # ensure out dir exists
  try:
    createDir("out")
  except:
    discard

  logLine(logfile, "=== New scan: target=" & target & " ports=" & $startP & "-" & $endP & " threads=" & $nThreads)

  var threadsArr: seq[Thread[void]] = @[]

  for i in 0..<nThreads:
    var t: Thread[void]
    createThread(t, proc() = worker(target, logfile))
    threadsArr.add(t)

  # wait all threads
  for t in threadsArr:
    joinThread(t)

  logLine(logfile, "=== Scan finished for " & target)
  echo "Scan complete. Results in ", logfile
