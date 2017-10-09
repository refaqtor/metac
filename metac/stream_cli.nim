import reactor, capnp, metac/instance, metac/schemas, metac/stream, metac/persistence, metac/cli_common, strutils, collections, cligen, reactor/process

proc streamFromUri*(instance: Instance, uri: string): Future[Stream] {.async.} =
  let s = uri.split(":", 1)
  let schema = s[0]
  let path = s[1]

  if schema == "ref":
    return instance.restore(uri.parseSturdyRef).castAs(Stream)
  else:
    raise newException(ValueError, "invalid URI")

proc catCmd(uri: string) =
  if uri == nil:
    raise newException(InvalidArgumentException, "")

  asyncMain:
    let instance = await newInstance()
    let stream = await instance.restore(parseSturdyRef(uri)).castAs(Stream)
    let fd = await instance.unwrapStreamAsPipe(stream)
    await zipVoid(@[
      pipe(createInputFromFd(0), fd.output),
      pipe(fd.input, createOutputFromFd(1)),
    ])

dispatchGen(catCmd, "metac stream cat", doc="Pipe data between stream and stdin/stdout.")

proc runConnectFdCmd(uri: string, args: seq[string]) =
  if uri == nil or args.len == 0:
    raise newException(InvalidArgumentException, "")

  asyncMain:
    let instance = await newInstance()
    let stream = await instance.restore(parseSturdyRef(uri)).castAs(Stream)
    let (fd, holder) = await instance.unwrapStream(stream)
    let process = startProcess(args,
                               additionalFiles = @[(cint(4), fd)],
                               additionalEnv = @[("LD_PRELOAD", bindfdPath), ("CONNECT_FD", "4")])
    let code = await process.wait()
    fakeUsage(holder)
    quit(code)

dispatchGen(runConnectFdCmd, "metac stream run-connectfd",
            doc="Run a process with TCP port 1 redirected to stream `uri` (uses bindfd.so LD_PRELOAD) ")

proc main*() =
  dispatchSubcommand({
    "cat": () => quit(dispatchCatCmd(argv)),
    "run-connectfd": () => quit(dispatchRunConnectFdCmd(argv)),
  })
