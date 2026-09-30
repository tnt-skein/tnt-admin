--- Маршруты страниц панели: то, что открывают браузером.
---
--- Страницы рисует узел шаблонизатором, а не браузер: разметка лежит
--- рядом с пакетом (`resources/views`), данные приходят из тех же
--- источников, что и в ответы API. Поэтому панель работает и без
--- сценариев: отбор — это адрес, действие — обычная форма.
---
--- Имён у этих маршрутов нет намеренно: имя — это договор с клиентом
--- API, а страницы открывают ссылкой, и в перечне API им места нет.

local router = require('tnt.router')

local can = require('tnt.admin.app.http.middleware.can')
local live = require('tnt.admin.app.services.live')
local pages = require('tnt.admin.app.services.pages')

--- Хвост шаблона маршрута: весь остаток пути вместе с косыми чертами.
---
--- Собран из двух кусков не для красоты: пара знаков «косая черта
--- со звёздочкой» в строке — это начало блочного комментария для
--- языконезависимого мутационного прогона, и всё, что стоит за ней,
--- он перестаёт видеть.
local TAIL = '/' .. '*path'

--- Разделы, которые показывают не всякому вошедшему, и их способность.
---
--- Та же, что у API: страница конфигурации показывает то же, что
--- `GET /api/v1/config`, а страница журнала — то же, что его выгрузка.
--- Без права на странице она стала бы дверью в обход API: наблюдатель,
--- которому API отказывает, читал бы конфигурацию страницей.
local ABILITIES = { config = can.CONFIG, audit = can.AUDIT }

--- Заголовки страницы потоком.
---
--- Обратный прокси просят не копить её: иначе первый кусок дошёл бы
--- до браузера вместе с последним, и поток сберёг бы память узла,
--- но не время до первой строки (документ `tnt-router`, «Выход в сеть»).
local STREAMED = { ['x-accel-buffering'] = 'no' }

---@param route TntRouter
---@param app TntDiContainer
return function(route, app)
    local source = app:get('admin_source')
    local gate = app:get('admin_gate')
    local guard = { app:get('admin_guard'), name = 'authorize' }

    --- Слои страницы: опознание, а где нужна способность — и право.
    ---
    --- Опознавание — на страницах тоже, а не только в API: страница
    --- показывает кластер, а форма действия его меняет. Файлы панели
    --- раздаются без него: браузер забирает стили до того, как оператор
    --- вошёл, и закрытый CSS показал бы страницу входа без оформления.
    ---@param ability string|nil
    ---@return table
    local function guarded(ability)
        if ability == nil then
            return { middleware = { guard } }
        end

        return { middleware = { guard, can.layer(gate, ability) } }
    end

    -- Толчок обзора: точка Centrifugo, если узел извещает о новых снимках.
    local pushed = live.new(source)

    for _, section in ipairs(pages.SECTIONS) do
        route.get(section.path, function(request)
            local data = pages[section.name](source, request.query or {})

            -- Адрес толчка страница получает только там, где точка есть:
            -- без него сценарий обновляет её опросом и не стучится
            -- в адрес, которого у панели нет. Потоковая страница рисует
            -- тот же макет, и адрес ей нужен так же.
            data.live = pushed ~= nil and live.PATH or nil

            -- Длинная страница рисуется в ответ по кускам: первые строки
            -- уходят, пока источник читает следующие, а в памяти узла
            -- лежит кусок, а не страница.
            if section.stream then
                return route.view_stream(section.name, data, nil, STREAMED)
            end

            return route.view(section.name, data)
        end, guarded(ABILITIES[section.name]))
    end

    -- Слоя опознания у точки нет: вход спрашивает её `connect`, и гость
    -- получает отказ Centrifugo 101, а не 401 на рукопожатии, после
    -- которого клиент переподключался бы без конца. Точка уходит роутеру
    -- ядра целиком, а не своим обработчиком: по `close_all` ядро узнаёт
    -- её и, отключая роутер, рвёт её сессии. Роутер пишет в объявлении
    -- функцию, поэтому запись приведена к ней.
    if pushed ~= nil then
        route.get(live.PATH, pushed --[[@as function]])
    end

    -- Действие со страницы приезжает формой: панель работает и без
    -- сценариев. После действия — переход, а не страница: обновление
    -- в браузере иначе повторяло бы его. Право то же, что у действия
    -- через API: форма — вторая дверь к тому же действию.
    route.post('/actions/run', function(request)
        local form = request.form or {}
        local targets = {}

        for target in tostring(form.targets or ''):gmatch('[^,]+') do
            table.insert(targets, target)
        end

        if source.act ~= nil then
            source.act(form.action, targets, request.identity, { reason = form.reason })
        end

        return router.redirect(form.back or '/')
    end, guarded(can.CHANGE))

    -- Файлы панели лежат не на диске, а в самом пакете: они приезжают
    -- вместе с кодом, и расхождения между версией панели и версией узла,
    -- которое случается, когда файлы раздаёт кто-то посторонний,
    -- не бывает.
    --
    -- Только GET: раздача отвечает на чтение, и объявить её на все
    -- способы значило бы обещать браузеру, что сюда можно писать.
    -- Запасной страницы у раздачи нет: адреса панель рисует сама, и путь,
    -- которого у неё нет, — это отказ, а не первая попавшаяся страница.
    if source.panel ~= nil then
        route.get(TAIL, router.files({ bundle = source.panel }))
    end
end
