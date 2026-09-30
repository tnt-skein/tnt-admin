--- Панель над источниками: роутер ядра с маршрутами и страницами пакета.
---
--- Обычный путь панели — роль (`tnt.admin`): её собирает фреймворк, и
--- узлу довольно назвать её в конфигурации. Но панель встраивают и в то,
--- что ролью не поднимается: в приложение со своим сервером и своими
--- воротами — оно разбирает cookie, считает неудачные попытки входа
--- и только потом отдаёт запрос панели. Такому нужна панель в виде
--- функции «запрос — ответ», и собирается она здесь.
---
--- Состав один и тот же: те же модули `routes/`, те же страницы
--- `resources/views`, тот же вид отказа. Разница — откуда приходят
--- источники: роли их собирает провайдер по установленным пакетам,
--- а здесь они названы вызывающим.

local di = require('tnt.di')
local http = require('tnt.kernel.http')
local pages_of = require('tnt.framework.pages')
local template = require('tnt.template')

local logging = require('tnt.log')

local authorize = require('tnt.admin.app.http.middleware.authorize')
local can = require('tnt.admin.app.http.middleware.can')
local handlers = require('tnt.admin.app.http.handlers.panel')
local refusals = require('tnt.admin.app.exceptions.refusal')
local root = require('tnt.admin.app.support.root')

local Module = {}

--- Имя журнала панели: под ним же пишет роль.
Module.TAG = 'tnt.admin'

--- Каталог страниц внутри раскладки пакета.
Module.VIEWS = 'resources/views'

--- Имена в контейнере: те же, что кладёт провайдер роли.
Module.SOURCE = 'admin_source'
Module.HANDLERS = 'admin_handlers'
Module.GUARD = 'admin_guard'
Module.GATE = 'admin_gate'

--- Маршруты панели: API и страницы, в том же порядке, что у роли.
---@param route TntRouter
---@param app TntDiContainer
local function declare(route, app)
    require('tnt.admin.routes.api')(route, app)
    require('tnt.admin.routes.web')(route, app)
end

---@class TntAdminPanelBuild
---@field dispatch fun(request: table): table Ответ панели на разобранный запрос
---@field attach fun(server: table) Подключение к серверу `http.server`
---@field routes fun(): table[] Маршруты, которые панель объявила

--- Собирает панель над названными источниками.
---@param source table Источники панели: снимок, находки, ворота, файлы
---@param settings table|nil Раздел `http` сверх умолчаний: пределы, срок, отладка
---@return TntAdminPanelBuild
function Module.new(source, settings)
    local app = di.new()

    app:value(Module.SOURCE, source)
    app:value(Module.GUARD, authorize.new(source))
    app:value(Module.GATE, can.gate())
    app:value(Module.HANDLERS, handlers.new(source))

    local given = settings or {}

    -- Вид тела отказа — свой: его читают и страницы панели, и её JS,
    -- и клиент API, и настройка соседнего приложения его не меняет.
    given.error_view = refusals.view

    local view = template.new({ path = ('%s/%s'):format(root.directory(), Module.VIEWS) })

    -- Сервер на сборке — заглушка: роутер собирается до того, как его
    -- есть куда подключать, и настоящий сервер приходит в `attach`.
    ---@type any
    local pending = { options = { handler = function() end } }

    local attachment = http.build({
        tag = Module.TAG,
        server = pending,
        settings = http.settings(given),
        view = view,
        pages = pages_of.of(view),
        container = app,
        routes = declare,
    })

    return {
        dispatch = attachment.router.dispatch,
        routes = attachment.router.routes,

        attach = function(server)
            attachment.server = server

            http.attach(attachment, logging.new(Module.TAG))
        end,
    }
end

return Module
