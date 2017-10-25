import reactor, capnp, metac/instance, metac/schemas, metac/stream, metac/persistence, metac/cli_common, strutils, collections, cligen

proc fileFromUri*[T: schemas.File|Filesystem](instance: Instance, uri: string, typ: typedesc[T]): Future[T] {.async.} =
  var (schema, path) = uri.split2(":")

  var root: Filesystem
  if schema == "local":
    var uid = uint32(0)
    var gid = uint32(0)

    while not path.startswith('/'):
      let (curr, rest) = path.split2(",")
      path = rest
      let (k, v) = curr.split2("=")
      if k == "uid":
        uid = parseBiggestInt(v).uint32
      elif k == "gid":
        gid = parseBiggestInt(v).uint32
      else:
        raise newException(ValueError, "invalid URI option $1" % [k])

    let fsService = await instance.getServiceAdmin("fs", FilesystemServiceAdmin)
    let ns = await fsService.rootNamespace
    root = await ns.filesystemForUser(uid, gid)
  elif schema == "ref":
    return instance.restore(uri.parseSturdyRef).castAs(T)
  else:
    raise newException(ValueError, "invalid URI")

  when typ is schemas.File:
    return root.getFile(path)
  else:
    return root.getSubtree(path)

proc fileFromUri*(instance: Instance, uri: string): auto = return fileFromUri(instance, uri, schemas.File)
proc fsFromUri*(instance: Instance, uri: string): auto = return fileFromUri(instance, uri, schemas.Filesystem)

defineExporter(fsExportCmd, fsFromUri)
defineExporter(fileExportCmd, fileFromUri)

proc catCmd(uri: string) =
  if uri == nil:
    raise newException(InvalidArgumentException, "")

  asyncMain:
    let instance = await newInstance()
    let file = await instance.fileFromUri(uri, schemas.File)
    let stream = await file.openAsStream()
    let fd = await instance.unwrapStreamAsPipe(stream)
    await pipe(fd.input, createOutputFromFd(1))

dispatchGen(catCmd, "metac file cat", doc="Show file contests.")

proc mountCmd(uri: string, path: string, persistent=false) =
  if uri == nil or path == nil:
    raise newException(InvalidArgumentException, "")

  asyncMain:
    let instance = await newInstance()
    let fs = await instance.fileFromUri(uri, schemas.Filesystem)
    let fsService = await instance.getServiceAdmin("fs", FilesystemServiceAdmin)
    let mnt = await fsService.rootNamespace.mount(MountInfo(path: path, fs: fs))

    let sref = await mnt.castAs(schemas.Persistable).createSturdyRef(nullCap, persistent)
    echo sref.formatSturdyRef

dispatchGen(mountCmd, "metac fs mount", doc="Mount a filesystem on a local path.")

proc openCmd(uri: string, persistent=false) =
  if uri == nil:
    raise newException(InvalidArgumentException, "")

  asyncMain:
    let instance = await newInstance()
    let file = await instance.fileFromUri(uri, schemas.File)
    let stream = await file.openAsStream()

    let sref = await stream.castAs(schemas.Persistable).createSturdyRef(nullCap, persistent)
    echo sref.formatSturdyRef

dispatchGen(openCmd, cmdName="metac file open", doc="Turn a file into a stream.")

proc cpCmd(src: string, dst: string) =
  if src == nil or dst == nil:
    raise newException(InvalidArgumentException, "")

  asyncMain:
    let instance = await newInstance()
    let srcFile = await instance.fsFromUri(src)
    let dstFile = await instance.fsFromUri(dst)
    # TODO: copy
    discard

dispatchGen(cpCmd, "metac fs cp", doc="Copy files from [src] to [dst].")

proc mainFile*() =
  dispatchSubcommand({
    "export": () => quit(dispatchFileExportCmd(argv, doc="")),
    "cat": () => quit(dispatchCatCmd(argv, doc="Print the file content to the standard output.")),
    "open": () => quit(dispatchOpenCmd(argv)),
  })

proc mainFs*() =
  dispatchSubcommand({
    "export": () => quit(dispatchFsExportCmd(argv)),
    "mount": () => quit(dispatchMountCmd(argv)),
    "cp": () => quit(dispatchCpCmd(argv)),
  })
