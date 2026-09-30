--- Маршруты API панели: адрес — обработчик из контейнера.
---
--- Обычный HTTP с JSON: код ответа настоящий, и панель смотрит на него,
--- а не разбирает текст. Обработчики берутся у контейнера, а источники
--- под ними приходят туда сборкой роли, — проверки подставляют двойника
--- одной строкой.
---
--- Слои входа — опознаватель запроса, трасса, запись о запросе, страж —
--- стоят у ядра: они одни на всякое приложение, и панель здесь объявляет
--- только своё опознание оператора и права на маршрутах.
---
--- Право называет маршрут, а не обработчик: слой `can` спрашивает ворота
--- панели до обработчика, и маршрут, объявленный без права, виден здесь
--- же, а не в теле функции. Маршруты чтения спрашивают только вход:
--- `cluster.read` есть у всякой личности панели — у наблюдателя прямо,
--- у администратора звёздочкой, — и слой на них ничего бы не решал.

local audit = require('tnt.admin.app.http.handlers.audit')
local instances = require('tnt.admin.app.http.handlers.instances')
local can = require('tnt.admin.app.http.middleware.can')

---@param route TntRouter
---@param app TntDiContainer
return function(route, app)
    local source = app:get('admin_source')
    local handlers = app:get('admin_handlers')
    local guard = app:get('admin_guard')
    local gate = app:get('admin_gate')

    --- Настройки маршрута, которому нужна способность: имя и слой права.
    ---@param name string
    ---@param ability string
    ---@return table
    local function needs(name, ability)
        return { name = name, middleware = { can.layer(gate, ability) } }
    end

    -- Выкладка метрик идёт мимо общего опознания: у сборщика нет ни
    -- cookie, ни сессии, и проверять его тем же способом значит закрыть
    -- выкладку насовсем. Вне общего префикса и намеренно: это не часть
    -- API панели, а договор со сборщиком, у которого свои привычки.
    route.get('/metrics', handlers.metrics, { name = 'metrics' })

    route.group('/api/v1', { middleware = { { guard, name = 'authorize' } } }, function(r)
        r.get('/cluster', handlers.cluster, { name = 'cluster' })
        r.get('/issues', handlers.issues, { name = 'issues' })
        r.get('/suggestions', handlers.suggestions, { name = 'suggestions' })
        r.get('/overview', handlers.overview, { name = 'overview' })
        r.get('/capabilities', handlers.capabilities, { name = 'capabilities' })
        r.post('/actions/assess', handlers.assess, needs('actions.assess', can.CHANGE))
        r.post('/actions', handlers.act, needs('actions.run', can.CHANGE))
        r.get('/config', handlers.show_config, needs('config.show', can.CONFIG))
        r.post('/config', handlers.apply_config, needs('config.apply', can.CHANGE))
        r.post('/login', handlers.login, { name = 'login' })

        instances.declare(r, source)
        audit.declare(r, source, gate)
    end)
end
