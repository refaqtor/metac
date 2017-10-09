import metac/cli_common

proc destroyCmd(uri: string) =
  if uri == nil:
    raise newException(InvalidArgumentException, "")

  asyncMain:
    let instance = await newInstance()
    let obj = await instance.restore(uri.parseSturdyRef).castAs(Destroyable)
    await obj.destroy

dispatchGen(destroyCmd, "metac destroy", doc="Destroy any destroyable object pointed by [uri].")

proc mainDestroy*() =
  dispatchDestroyCmd(argv).quit

proc mainJoinTestnet() =
  nil
