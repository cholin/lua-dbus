-- implementing awesome dbus api with ldbus

local ldbus = require "ldbus"

local dbus = {}

-- dbus loop

function dbus.init()
    dbus.signals = {}
    dbus.callbacks = {}
    dbus.session = ldbus.bus.get('session')
    dbus.system  = ldbus.bus.get('system')
end

function dbus.exit()
    dbus.signals = nil
    dbus.session = nil
    dbus.system  = nil
end

function dbus.poll()
    local ok = false
    for _, name in ipairs({'system', 'session'}) do
        local had_messages = false
        while dbus.process_request(dbus.poll_bus(name, dbus[name])) do
            had_messages = true
            ok = true
        end
        if had_messages then dbus[name]:flush() end
    end
    return ok
end

function dbus.poll_bus(bus_name, bus)
    if not bus then return end
    if bus:read_write(0) then
        local msg = bus:pop_message()
        if msg then
            local ret = { bus = bus, message = msg }
            ret.signal = {
                bus = bus_name,
                type = msg:get_type(),
                path = msg:get_path(),
                member = msg:get_member(),
                sender = msg:get_sender(),
                serial = msg:get_serial(),
                reply = msg:get_reply_serial(),
                signature = msg:get_signature(),
                interface = msg:get_interface(),
                destination = msg:get_destination(),
            }
            ret.iter = msg:iter_init()
            ret.args = dbus.iter_args(ret.iter)
            return ret
        end
    end
end

function dbus.process_request(req)
    if not req then return end
    print(req.signal.bus, req.signal.type, req.signal.interface, req.signal.path, req.signal.member, req.signal.sender, req.signal.destination, req.signal.signature, req.signal.serial, req.signal.reply, req.args)
    if _it and process.repl then pprint((req.args)) end
    if req.signal.reply > 0 then
        local callback = dbus.callbacks[req.signal.reply]
        local key = string.format("reply %d", req.signal.reply)
        for _, signal in ipairs(dbus.signals) do
            if signal.name == key then
                signal.callback(req.signal, unpack(req.args))
            end
        end
    end
    if req.message:get_no_reply() then
        for _, signal in ipairs(dbus.signals) do
            if signal.name == req.signal.interface then
                signal.callback(req.signal, unpack(req.args))
            end
        end
    else
        for _, signal in ipairs(dbus.signals) do
            if signal.name == req.signal.interface then
                local ret = {signal.callback(req.signal, unpack(req.args))}
                local reply = req.message:new_method_return()
                local iter = reply:iter_init_append(req.iter)
                for _, val in ipairs(ret) do
                    iter:append_basic(val)
                end
                req.bus:send(reply)
                return true -- there can be only ONE handler to send reply
            end
        end
    end
    return true
end

function dbus.iter_args(iter, alltype)
    local args = { len = 0 }
    if not iter then return args end
    typ = alltype or iter:get_arg_type()
    while true do
        if not typ then
            args.len = args.len + 1
            args[args.len] = nil
        elseif typ == ldbus.types.variant or typ == ldbus.types.dict_entry then
            local nargs = dbus.iter_args(iter:recurse())
            for i = 1, nargs.len do
                args[args.len + i] = nargs[i]
            end
            args.len = args.len + nargs.len
        elseif typ == ldbus.types.struct then
            local nargs = dbus.iter_args(iter:recurse())
            args.len = args.len + 1
            args[args.len] = nargs
        elseif typ == ldbus.types.array then
            local nargs = dbus.iter_args(iter:recurse(), iter:get_element_type())
            args.len = args.len + 1
            args[args.len] = nargs
        else
            args.len = args.len + 1
            args[args.len] = iter:get_basic()
        end
        if iter:next() then
            typ = alltype or iter:get_arg_type()
        else
            break
        end
    end
    return args
end

function dbus.get_bus(name)
    if name == 'session' then
        return dbus.session
    elseif name == 'system' then
        return dbus.system
    end
end

-- awesome dbus api

function dbus.request_name()
    local bus = dbus.get_bus(bus_name)
    if not bus then return end
    return ({
        primary_owner = true,
        already_owner = true,
    })[ldbus.bus.request_name(bus, name)] or false
end

function dbus.release_name(bus_name, name)
    local bus = dbus.get_bus(bus_name)
    if not bus then return end
    return ldbus.bus.release_name(bus, name) == 'released'
end

function dbus.add_match(bus_name, name)
    local bus = dbus.get_bus(bus_name)
    if not bus then return end
    ldbus.bus.add_match(bus, name)
    bus:flush()
end

function dbus.remove_match(bus_name, name)
    local bus = dbus.get_bus(bus_name)
    if not bus then return end
    ldbus.bus.remove_match(bus, name)
    bus:flush()
end

function dbus.connect_signal(name, callback)
    table.insert(dbus.signals, {name = name, callback = callback})
end

function dbus.disconnect_signal(name, callback)
    for i, signal in ipairs(dbus.signals) do
        if signal.name == name and signal.callback == callback then
            table.remove(dbus.signals, i)
            return
        end
    end
end

function dbus.emit_signal(bus_name, path, iface, name, ...)
    local args = {...}
    local bus = dbus.get_bus(bus_name)
    if not bus then return false end
    local msg = ldbus.message.new_signal(path, iface, name)
    if not msg then return false end
    local iter = msg:iter_init_append()
    if not iter then return false end
    for i=1,#args,2 do
        local typ, val = args[i], args[i+1]
        if typ and val then
            iter:append_basic(val, typ)
        end
    end
    local ok = bus:send(msg)
    bus:flush()
    return ok
end

function dbus.call_method(bus_name, dest, path, iface, method, ...)
    local args = {...}
    local bus = dbus.get_bus(bus_name)
    if not bus then return false end
    local msg = ldbus.message.new_method_call(dest, path, iface, method)
    if not msg then return false end
    local iter = msg:iter_init_append()
    if not iter then return false end
    for i=1,#args,2 do
        local typ, val = args[i], args[i+1]
        if typ and val then
            iter:append_basic(val, typ)
        end
    end
    local ok, serial = bus:send(msg)
    bus:flush()
    return ok and serial or 0
end


return dbus