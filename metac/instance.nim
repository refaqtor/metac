import metac/schemas, caprpc, posix, reactor, reactor/unix, os, tables, collections, metac/process_util

type
  Instance* = ref object
    rpcSystem: RpcSystem
    localRequests*: TableRef[string, RootRef] # for castToLocal
    address*: string
    thisNode*: Node
    thisNodeAdmin*: NodeAdmin
    isAdmin*: bool

  ServiceInstance* = ref object
    instance*: Instance
    persistenceHandler*: ServicePersistenceHandler
    serviceName: string

let notAuthorized* = inlineCap(CapServer, CapServerInlineImpl(
  call: (proc(ifaceId: uint64, methodId: uint64, args: AnyPointer): Future[AnyPointer] =
             return now(error(AnyPointer, "not authorized to access admin interface (run as root)")))
))

proc newInstance*(): Future[Instance] {.async.} =
  let self = Instance()
  self.localRequests = newTable[string, RootRef]()

  var conn: BytePipe
  let userSocket = "/run/metac/user/$1/socket" % [$getuid()]

  if access(userSocket, F_OK) == 0:
    self.isAdmin = true
    conn = await connectUnix(userSocket)
  else:
    conn = await connectTcp("::1", 901)

  self.rpcSystem = newRpcSystem(newTwoPartyNetwork(conn, Side.client).asVatNetwork)

  if self.isAdmin:
    self.thisNodeAdmin = (await self.rpcSystem.bootstrap()).castAs(NodeAdmin)
    self.thisNode = await self.thisNodeAdmin.getUnprivilegedNode()
  else:
    self.thisNodeAdmin = NodeAdmin.createFromCap(notAuthorized)
    self.thisNode = (await self.rpcSystem.bootstrap()).castAs(Node)

  let nodeAddr = await self.thisNode.address()
  self.address = nodeAddr.ip

  return self

proc nodeAddress*(instance: Instance): NodeAddress =
  return NodeAddress(ip: instance.address)

proc getServiceAdmin*[T](instance: Instance, name: string, typ: typedesc[T]): Future[T] {.async.} =
  let service = await instance.thisNodeAdmin.getServiceAdmin(name)
  return service.castAs(T)

proc translateServiceName*(name: string): string =
  if getuid() == 0:
    return name
  else:
    return "user-$1-$2" % [$getuid(), name]

proc waitForService*(instance: Instance, name: string): Future[void] {.async.} =
  await instance.thisNode.waitForService(ServiceId(kind: ServiceIdKind.named, named: translateServiceName(name)))

proc connect*(instance: Instance, address: NodeAddress): Future[Node] {.async.} =
  # TODO: multiparty RpcSystem
  let conn = await connectTcp(address.ip, 901)
  let rpcSystem = newRpcSystem(newTwoPartyNetwork(conn, Side.client).asVatNetwork)
  return rpcSystem.bootstrap().castAs(Node)

proc `$`*(instance: Instance): string =
  return "Instance@" & instance.address

proc fakeUsage*(a: any) =
  # forces GC to keep `a` to the point of this call
  var v {.volatile.} = a

### ServiceInstance

proc newServiceInstance*(name: string): Future[ServiceInstance] {.async.} =
  let instance = await newInstance()
  if name != "persistence":
    await instance.waitForService("persistence")

  let persistenceHandler = if name != "persistence":
                             await instance.getServiceAdmin("persistence", PersistenceServiceAdmin).getHandlerFor(ServiceId(kind: ServiceIdKind.named, named: name))
                           else:
                             nullCap

  return ServiceInstance(instance: instance, serviceName: name, persistenceHandler: persistenceHandler)

proc runService*(sinstance: ServiceInstance, service: Service, adminBootstrap: ServiceAdmin) {.async.} =
  ## Helper method for registering and running a service
  let holder = await sinstance.instance.thisNodeAdmin.registerNamedService(sinstance.serviceName, service, adminBootstrap)
  await systemdNotifyReady()
  stderr.writeLine(sinstance.serviceName & ": ready")
  await holder.castAs(Waitable).wait
  fakeUsage holder

converter toInstance*(s: ServiceInstance): Instance =
  return s.instance

### castToLocal

template enableCastToLocal*(T) =
  proc registerLocal*(self: T, key: string) {.async.} =
    if key notin self.instance.toInstance.localRequests:
      asyncRaise "invalid key"

    self.instance.toInstance.localRequests[key] = self

proc toLocal*[T, R](instance: Instance, self: T, target: typedesc[R]): Future[R] {.async.} =
  let key = hexUrandom(16)
  instance.localRequests[key] = nil
  await self.castAs(CastToLocal).registerLocal(key)
  let val = instance.localRequests[key]
  instance.localRequests.del key
  if val == nil:
    asyncRaise "toLocal request not completed"
  if not (val of R):
    asyncRaise "toLocal response bad type"
  return val.R

###

type HolderImpl[T] = ref object of RootRef
  obj: T

proc toCapServer*(self: HolderImpl): CapServer =
  return toGenericCapServer(self.asHolder)

proc holder*[T](t: T): schemas.Holder =
  when T is void:
    return HolderImpl[T]().asHolder
  else:
    return HolderImpl[T](obj: t).asHolder

### UTILS

proc waitForFile*(path: string) {.async.} =
  var buf: Stat
  while stat(path.cstring, buf) != 0:
    await asyncSleep(10)

### Adjustments

GC_disableMarkAndSweep() # mark and sweep causes issues with destructors
