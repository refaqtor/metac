import posix, os, selectors, collections

var OPUS_APPLICATION_AUDIO {.importc, header: "<opus/opus.h>".}: cint
var SOL_TCP {.importc, header: "<stdlib.h>".}: cint

type OpusEncoder = object
type OpusDecoder = object

proc opus_encode (st: ptr OpusEncoder, pcm: ptr uint16, frame_size: cint, data: cstring, max_data_bytes: int32): int32 {.importc, header: "<opus/opus.h>".}
proc opus_encoder_create (fs: int32, channels: cint, application: cint, error: ptr cint): ptr OpusEncoder {.importc, header: "<opus/opus.h>".}
proc opus_encoder_ctl (st: ptr OpusEncoder, request: int): cint {.importc, varargs, header: "<opus/opus.h>".}

proc opus_decoder_create (fs: int32, channels: cint, error: ptr cint): ptr OpusDecoder {.importc, header: "<opus/opus.h>".}
proc opus_decode (st: ptr OpusDecoder, data: cstring, len: int32, pcm: ptr int16, frame_size: cint, decode_fec: cint): cint {.importc, header: "<opus/opus.h>".}

{.passl: "-lopus".}

const
  rate = 48000
  channels = 2
  frameSize = 960
  bitrate = 128000

proc readAll(buff: var string): bool =
  var pos = 0
  while pos < buff.len:
    let res = read(0, addr buff[pos], buff.len - pos)
    if res <= 0: return false
    pos += res

  return true

proc encoderMain*() =
  var err: cint
  let encoder = opus_encoder_create(rate, channels, OPUS_APPLICATION_AUDIO, addr err)
  if err != 0:
    stderr.write "failed to create encoder"
    quit(1)

  #if opus_encoder_ctl(encoder, 4002, int32(bitrate)) != cint(0):
  #  stderr.write "failed to set bitrate"
  #  quit(1)

  var sndbuf: cint = 2048
  discard setsockopt(SocketHandle(1), SOL_SOCKET, SO_SNDBUF, addr sndbuf, sizeof(sndbuf).Socklen)

  var one: cint = 1
  discard setsockopt(SocketHandle(1), SOL_TCP, TCP_NODELAY, addr one, sizeof(one).Socklen)

  var outBuffer = newString(5000)
  var inBuffer = newString(frameSize * 2 * channels)

  while true:
    if not readAll(inBuffer):
      break

    #stderr.writeLine("$1 $2" % [$inBuffer.len, inBuffer.encodeHex])
    var encodedSize: int32 = opus_encode(encoder, cast[ptr uint16](addr inBuffer[0]), frameSize, addr outBuffer[4], (outBuffer.len - 4).int32)
    if encodedSize < 0:
      stderr.writeLine "opus_encode failed"
      return

    # stderr.writeLine encodedSize
    assert encodedSize <= outBuffer.len - 4
    let encodedSizeStr = pack(encodedSize, littleEndian)
    copyMem(addr outBuffer[0], unsafeAddr encodedSizeStr[0], encodedSizeStr.len)
    encodedSize += 4

    var writeSet: TFdSet
    var readSet: TFdSet
    var errorSet: TFdSet
    FD_ZERO(writeSet); FD_ZERO(readSet); FD_ZERO(errorSet)
    FD_SET(1, writeSet)
    discard select(cint(2), addr readSet, addr writeSet, addr errorSet, nil)

    if FD_ISSET(cint(1), writeSet) != 0:
      let res = write(1, addr outBuffer[0], encodedSize)
      if res != encodedSize:
        stderr.writeLine "write failed"
        quit(0)
    else:
      stderr.writeLine "write dropped"

proc decoderMain*() =
  var err: cint
  let decoder = opus_decoder_create(rate, channels, addr err)
  if err != 0:
    stderr.write "failed to create decoder"
    quit(1)


  var packetSizeBuf = newString(4)
  var outBuffer = ""
  var inBuffer = newString(frameSize * 2 * channels)

  while true:
    if not readAll(packetSizeBuf):
      break

    let packetSize = unpack(packetSizeBuf, uint32, littleEndian)
    if packetSize >= 5000.uint32:
      stderr.writeLine "invalid packet size ", $packetSize
      quit(1)

    outBuffer.setLen(packetSize)
    if not readAll(outBuffer):
      break

    let samples = opus_decode(decoder, outBuffer, outBuffer.len.int32, cast[ptr int16](addr inBuffer[0]), frameSize, 0)
    if samples < 0:
      stderr.writeLine "opus_decode failed"
      return
    let decodedSize = samples * 2 * channels

    let res = write(1, addr inBuffer[0], decodedSize)
    if res != decodedSize:
      stderr.writeLine "write failed"
      quit(0)
