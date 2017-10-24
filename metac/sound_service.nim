import os, reactor, caprpc, metac/instance, metac/schemas, collections, reactor/process, reactor/file, metac/process_util, osproc, posix
import metac/stream, metac/persistence
import metac/sound_schema

type
  SoundServiceAdminImpl = ref object of RootObj
    instance: ServiceInstance
    systemMixer: MixerImpl
    systemMixerMutex: AsyncMutex

  MixerImpl = ref object of RootObj
    instance: ServiceInstance
    socketPath: string

  SoundDeviceImpl = ref object of PersistableObj
    # either a sink or a source
    mixer: MixerImpl
    isSink: bool
    name: string

proc info(self: SoundDeviceImpl): Future[SoundDeviceInfo] {.async.} =
  return SoundDeviceInfo(name: self.name,
                         isSink: self.isSink,
                         isHardware: self.name.startswith("alsa_"))

proc opusStream(self: SoundDeviceImpl): Future[Stream] {.async.} =
  # be somehow more intelligent about format and OPUS parameters
  # (and use RTP in future)
  let opts = "-d $1" % [quoteShell(self.name)]
  var cmd: string
  if self.isSink:
    cmd = "metac sound-rtopus-decode | paplay --latency-msec=10 --channels=2 --format=s16le --rate=48000 --raw $1" % [opts]
  else:
    cmd = "parec --latency-msec=10 --channels=2 --format=s16le --rate=48000 --file-format=raw $1 | metac sound-rtopus-encode" % [opts]

  let pFd: cint = if self.isSink: 0 else: 1
  echo "launching ", cmd
  let process = startProcess(@["sh", "-c", cmd],
                             additionalFiles = @[(2.cint, 2.cint)],
                             additionalEnv = @[
                               ("PULSE_SERVER", "unix:" & self.mixer.socketPath)],
                             pipeFiles= @[pFd])

  return self.mixer.instance.wrapStream(process.files[0])

proc bindTo(self: SoundDeviceImpl, other: SoundDevice): Future[Holder] {.async.} =
  let selfStream = await self.opusStream
  let otherStream = await other.opusStream
  let holder = await selfStream.bindTo(otherStream)
  return injectBasicPersistence(self.mixer.instance, holder)

capServerImpl(SoundDeviceImpl, [SoundDevice, Persistable, Waitable])

proc createDevice(self: MixerImpl, name: string, sink: bool, runtimeId: string=nil): Future[SoundDevice] {.async.} =
  let name = "metac." & hexUrandom(5) & "." & name
  let sinkOrSource = if sink: "sink" else: "source"
  await execCmd(@["pactl", "--server=" & self.socketPath, "load-module", "module-null-" & sinkOrSource, sinkOrSource & "_name=" & name, sinkOrSource & "_properties=device.description=" & name])
  let monitorName = name & ".monitor"

  return SoundDeviceImpl(mixer: self,
                         isSink: not sink,
                         name: monitorName,
                         persistenceDelegate: self.instance.makePersistenceDelegate(
                           category=if not sink: "sound:newsink" else: "sound:newsource",
                           description=toAnyPointer(name),
                           runtimeId=runtimeId)).asSoundDevice

proc createSink(self: MixerImpl, name: string): Future[SoundDevice] {.async.} =
  return createDevice(self, name, sink=true)

proc createSource(self: MixerImpl, name: string): Future[SoundDevice] {.async.} =
  # TODO: this doesn't work, because sources don't have monitors
  return createDevice(self, name, sink=false)

proc getSink(self: MixerImpl, name: string, runtimeId: string=nil): Future[SoundDevice] {.async.} =
  return SoundDeviceImpl(mixer: self, isSink: true, name: name,
                         persistenceDelegate: self.instance.makePersistenceDelegate("sound:sink", toAnyPointer(name), runtimeId)).asSoundDevice

proc getSource(self: MixerImpl, name: string, runtimeId: string=nil): Future[SoundDevice] {.async.} =
  return SoundDeviceImpl(mixer: self, isSink: false, name: name,
                         persistenceDelegate: self.instance.makePersistenceDelegate("sound:source", toAnyPointer(name), runtimeId)).asSoundDevice

proc getDevices(self: MixerImpl): Future[seq[SoundDevice]] {.async.} =
  await execCmd(@["pactl", "--server=" & self.socketPath, "list"])
  return @[] # TODO

capServerImpl(MixerImpl, [Mixer])

proc mkdtemp(tmpl: cstring): cstring {.importc, header: "stdlib.h".}

proc getUserMixer(self: SoundServiceAdminImpl): Future[MixerImpl] {.async.} =
  # user mixer
  await execCmd(@["pulseaudio", "--start"]) # starts only if needed
  await execCmd(@["pactl", "unload-module", "module-suspend-on-idle"])
  let runtimeDir = if existsEnv("XDG_RUNTIME_DIR"): getEnv("XDG_RUNTIME_DIR") else: "/run/user/" & $(getuid())
  let path = runtimeDir & "/pulse/native"
  return MixerImpl(instance: self.instance, socketPath: path)

proc getSystemMixer(self: SoundServiceAdminImpl): Future[MixerImpl] {.async.} =
  await self.systemMixerMutex.lock
  defer: self.systemMixerMutex.unlock

  if self.systemMixer == nil:
    let mixer = MixerImpl(instance: self.instance)

    var dirPath = "/tmp/metac_pulse_XXXXXXXX"
    if mkdtemp(dirPath) == nil:
      raiseOSError(osLastError())
    await execCmd(@["chown", "pulse:root", dirPath])
    await execCmd(@["chmod", "770", dirPath])

    mixer.socketPath = dirPath & "/socket"
    echo "spawning PulseAudio..."
    let process =
      startProcess(@["pulseaudio",
                     "--system", "-n",
                     "--disallow-exit", "--use-pid-file=false",
                     "--load=module-always-sink",
                     "--load=module-rescue-streams",
                     "--load=module-suspend-on-idle",
                     "--load=module-udev-detect",
                     "--load=module-native-protocol-unix auth-anonymous=1 socket=" & mixer.socketPath],
                   additionalEnv = @[("DBUS_SYSTEM_BUS_ADDRESS", "none")],
                   additionalFiles = [(1.cint, 1.cint), (2.cint, 2.cint)])
    await waitForFile(mixer.socketPath)
    echo "PulseAudio started"

    self.systemMixer = mixer
    discard process

  return self.systemMixer

proc getDefaultMixerInternal(self: SoundServiceAdminImpl): Future[MixerImpl] =
  if getuid() == 0:
    return getSystemMixer(self)
  else:
    return getUserMixer(self)

proc getDefaultMixer(self: SoundServiceAdminImpl): Future[Mixer] {.async.} =
  let mixer = await self.getDefaultMixerInternal()
  return mixer.asMixer

capServerImpl(SoundServiceAdminImpl, [SoundServiceAdmin])

proc main*() {.async.} =
  let instance = await newServiceInstance("sound")

  let serviceImpl = SoundServiceAdminImpl(instance: instance, systemMixerMutex: newAsyncMutex())
  let serviceAdmin = serviceImpl.asSoundServiceAdmin

  proc restorer(d: CapDescription): Future[AnyPointer] {.async.} =
      let mixer = await serviceImpl.getDefaultMixerInternal
      case d.category:
      of "sound:sink":
        return mixer.getSink(d.description.castAs(string), d.runtimeId).toAnyPointerFuture
      of "sound:source":
        return mixer.getSource(d.description.castAs(string), d.runtimeId).toAnyPointerFuture
      of "sound:newsink":
        return mixer.createDevice(d.description.castAs(string), runtimeId=d.runtimeId, sink=false).toAnyPointerFuture
      of "sound:newsource":
        return mixer.createDevice(d.description.castAs(string), runtimeId=d.runtimeId, sink=false).toAnyPointerFuture
      else:
        return error(AnyPointer, "unknown category")

  await instance.registerRestorer(restorer)

  await instance.runService(
    service=Service.createFromCap(nothingImplemented),
    adminBootstrap=serviceAdmin.castAs(ServiceAdmin)
  )

when isMainModule:
  main().runMain()
