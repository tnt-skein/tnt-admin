--- Слой панели: кто выполняет запрос.
---
--- Опознание приходит от приложения, а не от панели: она не знает, где
--- у кластера пользователи и чем они доказывают, кто они. Панель знает
--- только, что без ответа `authorize` запрос дальше не идёт.
---
--- Слоем, а не проверкой в каждом обработчике: право на чтение журнала
--- и право менять кластер разные, и разбирать их по обработчикам значит
--- однажды забыть об этом в новом.

local refusals = require('tnt.admin.app.exceptions.refusal')

local Module = {}

--- Права панели, открытой без входа.
---
--- Полные, и чтение журнала аудита тоже: панель без входа иначе была бы
--- бесполезна. Это осознанный выбор развёртывания — закрывают её сетью
--- либо воротами приложения, а не пустым `authorize`.
Module.OPEN = { readonly = false, audit = true }

--- Кто выполняет запрос: личность либо `nil, причина`.
---
--- Одно правило на все двери панели: страницы и API спрашивают его
--- слоем, а подключение Centrifugo (`tnt.admin.app.services.live`) —
--- в своём `connect`. Правило, записанное дважды, разошлось бы при первой
--- правке, и толчок пускал бы того, кому страница отказывает.
---@param source TntAdminSource
---@param request table
---@return TntAdminIdentity|nil identity
---@return string|nil reason
function Module.identify(source, request)
    if source.authorize == nil then
        return Module.OPEN
    end

    return source.authorize(request)
end

--- Собирает слой опознавания над источниками.
---@param source TntAdminSource
---@return fun(request: table, nxt: fun(request: table): any): any
function Module.new(source)
    return function(request, nxt)
        local identity, reason = Module.identify(source, request)

        if identity == nil then
            return refusals.refuse('unauthenticated', { reason = reason })
        end

        request.identity = identity

        return nxt(request)
    end
end

return Module
