--- Ends every squished driver: once late init returns, squish's package.preload copy of each loaded module only
--- holds memory, so it goes. A module not loaded yet keeps its copy, and so does a C loader, LuaJIT's own included.
OnDriverLateInit = (function(lateInit)
  local function dropLoadedCopies()
    for name, loader in pairs(package.preload) do
      if package.loaded[name] ~= nil and type(loader) == "function" and debug.getinfo(loader, "S").what == "Lua" then
        package.preload[name] = nil
      end
    end
  end

  local function afterLateInit(...)
    dropLoadedCopies()
    return ...
  end

  return function(...)
    if lateInit then
      return afterLateInit(lateInit(...))
    end
    dropLoadedCopies()
  end
end)(OnDriverLateInit)
