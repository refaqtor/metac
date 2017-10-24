import capnp, reactor, metac/schemas, collections, os, reactor/unix, metac/process_util, sequtils, posix

type
  InternalServiceId = tuple[isNamed: bool, name: string]

  Bridge = ref object of RootObj
    services: TableRef[InternalServiceId, ServiceInfo]
    nodeAddress: string
    waitFor: TableRef[InternalServiceId, Completer[void]]

  ServiceInfo = tuple[service: Service, serviceAdmin: ServiceAdmin]

  ServiceHolder = ref object of RootRef
    bridge: Bridge
    id: InternalServiceId

forwardDecl(Node, bridge, Bridge)
forwardDecl(NodeAdmin, bridge, Bridge)

capServerImpl(Bridge, [Node, NodeAdmin])

proc wait(h: ServiceHolder) {.async.} =
  await waitForever()

capServerImpl(ServiceHolder, [Holder, Waitable])

proc unregisterService(holder: ServiceHolder) =
  holder.bridge.services.del holder.id

proc registerNamedService(bridge: Bridge, name: string, service: Service, adminBootstrap: ServiceAdmin): Future[Holder] {.async.} =
  let iid = (true, name)
  bridge.services[iid] = (service, adminBootstrap)

  if iid in bridge.waitFor:
    let completer = bridge.waitFor[iid]
    bridge.waitFor.del iid
    completer.complete

  var holder: ServiceHolder
  new(holder, unregisterService)
  holder.bridge = bridge
  holder.id = (true, name)
  return holder.asHolder

proc getServiceAdmin(bridge: Bridge, name: string): Future[ServiceAdmin]  {.async.} =
  return bridge.services[(true, name)].serviceAdmin

proc toInternalId(id: schemas.ServiceId): InternalServiceId =
  if id.kind == schemas.ServiceIdKind.named:
    return (true, id.named)
  else:
    return (false, id.anonymous)

proc getService(bridge: Bridge, id: schemas.ServiceId): Future[Service] {.async.} =
  return bridge.services[toInternalId(id)].service

proc waitForService(bridge: Bridge, id: schemas.ServiceId): Future[void] {.async.} =
  let iid = toInternalId(id)
  if iid in bridge.services:
    return

  if iid notin bridge.waitFor:
    bridge.waitFor[iid] = newCompleter[void]()

  let completer = bridge.waitFor[iid]
  await completer.getFuture

proc getUnprivilegedNode(bridge: Bridge): Future[Node] {.async.} =
  return restrictInterfaces(bridge, Node)

proc registerAnonymousService(bridge: Bridge, service: Service): Future[Node_registerAnonymousService_Result] {.async.} =
  asyncRaise "not implemented"

proc address(bridge: Bridge): Future[NodeAddress] {.async.} =
  return NodeAddress(ip: bridge.nodeAddress)

proc startHusarnet(): Future[string] {.async.} =
  doAssert false, "todo"

proc createRestrictedBridgeAdmin(bridge: Bridge, prefix: string): NodeAdmin =
  return inlineCap(NodeAdmin, NodeAdminInlineImpl(
    getServiceAdmin: (
      proc(name: string): auto =
        return bridge.getServiceAdmin(prefix & name)),
    registerNamedService: (
      proc(name: string, service: Service, adminBootstrap: ServiceAdmin): auto =
        return bridge.registerNamedService(prefix & name, service, adminBootstrap)),
    getUnprivilegedNode: (proc(): auto = bridge.getUnprivilegedNode())
  ))

proc main*() {.async.} =
  enableGcNoDelay()

  var nodeAddr: string

  if existsEnv("METAC_MANUAL_NETWORK"):
    nodeAddr = getEnv("METAC_ADDRESS")
  else:
    nodeAddr = await startHusarnet()

  let baseDir = "/run/metac/"
  createDir("/run/metac")

  let bridge = Bridge(services: newTable[InternalServiceId, ServiceInfo](),
                      waitFor: newTable[InternalServiceId, Completer[void]](),
                      nodeAddress: nodeAddr)


  let node = restrictInterfaces(bridge, Node)

  let tcpServer = await createTcpServer(addresses = @[parseAddress(nodeAddr)], port=901)
  tcpServer.incomingConnections.forEach(proc(conn: auto) = discard newTwoPartyServer(conn, node.toCapServer)).ignore

  var users = getEnv("METAC_ALLOWED_USERS").splitWhitespace().map(x => parseInt(x))
  users.add(0)

  createDir(baseDir)
  createDir(baseDir & "/user")

  for user in users:
    let socketDir = baseDir & "/user/" & ($user)

    if not existsDir(socketDir):
      if mkdir(socketDir, 0o700) != 0:
        raiseOSError(osLastError())

    if chown(socketDir, user, 0) != 0:
      raiseOSError(osLastError())

    let socketPath = socketDir & "/socket"
    removeFile(socketPath)
    let unixServer = createUnixServer(socketPath)

    if chown(socketPath, user, 0) != 0:
      raiseOSError(osLastError())

    (proc(user: int) =
       let prefix = if user == 0: ""
                    else: ("user-" & $user & "-")
       let nodeAdmin = createRestrictedBridgeAdmin(bridge, prefix)
       unixServer.incomingConnections.forEach(proc(conn: auto) = discard newTwoPartyServer(conn, nodeAdmin.toCapServer)).ignore
    )(user)

  await systemdNotifyReady()
  await waitForever()
