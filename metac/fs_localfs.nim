# included from metac/fs.nim

type
  LocalFilesystem = ref object of PersistableObj
    instance: ServiceInstance
    info: FsInfo

proc getSubtree(fs: LocalFilesystem, path: string): Future[Filesystem] {.async.}
proc v9fsStream(fs: LocalFilesystem): Future[Stream] {.async.}
proc getFile(fs: LocalFilesystem, path: string): Future[schemas.File] {.async.}
proc summary(fs: LocalFilesystem): Future[string] {.async.} = return fs.info.path
proc readonlyFs(fs: LocalFilesystem): Future[schemas.Filesystem] {.async.}
proc sftpStream(fs: LocalFilesystem): Future[Stream] {.async.}

capServerImpl(LocalFilesystem, [Filesystem, Persistable, Waitable])

proc localFs*(instance: ServiceInstance, info: FsInfo, persistenceDelegate: PersistenceDelegate=nil): schemas.Filesystem =
  ## Return Filesystem cap for local filesystem on path ``path``.
  return LocalFilesystem(instance: instance, info: info, persistenceDelegate: persistenceDelegate).asFilesystem

proc localFsPersistable(instance: ServiceInstance, info: FsInfo): schemas.Filesystem =
  return localFs(instance, info, instance.makePersistenceDelegate(
    category="fs:localfs", description=toAnyPointer(info)))

proc getSubtree(fs: LocalFilesystem, path: string): Future[Filesystem] {.async.} =
  let newInfo = FsInfo(path: safeJoin(fs.info.path, path), uid: fs.info.uid,
                       gid: fs.info.gid)
  if fs.info.path == "/":
    return localFsPersistable(fs.instance, newInfo)
  else:
    return localFs(fs.instance, newInfo,
                   makePersistenceCallDelegate(fs.instance, fs.asFilesystem, Filesystem_getSubtree_Params(name: path)))

proc getFile(fs: LocalFilesystem, path: string): Future[schemas.File] {.async.} =
  let newInfo = FsInfo(path: safeJoin(fs.info.path, path), uid: fs.info.uid,
                       gid: fs.info.gid)

  if fs.info.path == "/":
    return localFilePersistable(fs.instance, newInfo)
  else:
    return localFile(fs.instance, newInfo,
                     makePersistenceCallDelegate(fs.instance, fs.asFilesystem, Filesystem_getFile_Params(name: path)))

proc readonlyFs(fs: LocalFilesystem): Future[schemas.Filesystem] {.async.} =
  asyncRaise "not implemented"

const diodPath {.strdefine.} = "metac-diod"
const sftpServerPath {.strdefine.} = "metac-sftp-server"

proc v9fsStream(fs: LocalFilesystem): Future[Stream] {.async.} =
  asyncRaise "v9fsStream support disabled"
  echo "starting diod... (path: $1)" % fs.info.path

  let dirFd = await openAt(fs.info.path)
  defer: discard close(dirFd)

  let process = startProcess(@[getAppDir() / diodPath, "--foreground", "--no-auth", "--logdest", "stderr", "--rfdno", "4", "--wfdno", "4", "--export", "/", "-c", "/dev/null", "--chroot-to", "3", "--no-userdb"],
                             pipeFiles = [4.cint],
                             additionalFiles = [(3.cint, dirFd.cint),
                                                (0.cint, 2.cint), (1.cint, 2.cint), (2.cint, 2.cint)])

  process.wait.then(proc(status: int) = echo("diod exited with code ", status)).ignore

  let v9fsPipe = BytePipe(input: process.files[0].input,
                          output: process.files[0].output)

  return fs.instance.wrapStream(v9fsPipe)

proc sftpStream(fs: LocalFilesystem): Future[Stream] {.async.} =
  # TODO: run directly on the TCP connection
  echo "starting SFTP server... (path: $1)" % fs.info.path

  var pair: array[0..1, cint]
  if socketpair(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC, 0, pair) != 0:
    asyncRaise "socketpair call failed"

  let fd = pair[0]
  defer: discard (close fd)

  let pipe = streamFromFd(pair[1])
  let dirFd = await openAt(fs.info.path)
  defer: discard close(dirFd)

  let cmd = @[getAppDir() / sftpServerPath,
              "-e", # stderr instead of syslog
              "-C", "4", # chroot to
              "-U", $(fs.info.uid), # setuid
  ]

  let process = startProcess(cmd,
                             additionalFiles= [(0.cint, fd.cint), (1.cint, fd.cint), (2.cint, 2.cint), (4.cint, dirFd.cint)],
                             gid=fs.info.gid)

  process.wait.then(proc(status: int) = echo("SFTP server exited with code ", status)).ignore

  return fs.instance.wrapStream(pipe)
