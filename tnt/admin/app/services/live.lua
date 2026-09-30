--- Толчок обзора: узел сам говорит браузеру, что кластер снят заново.
---
--- Страницы панели рисует узел, и о перемене в кластере браузер узнавал
--- опросом раз в пять секунд: оператор видел её с задержкой до пяти
--- секунд сверх обхода, а каждая открытая вкладка спрашивала узел, даже
--- когда нового не было. Теперь на каждый новый снимок узел публикует
--- обзор в канал Centrifugo (`tnt-centrifugo`), а браузер, подписанный
--- официальным клиентом `centrifuge-js`, перерисовывает страницу
--- по толчку. Опрос остаётся запасным путём на время обрыва.
---
--- Вход — тот же, что у страниц: `connect` спрашивает опознание панели
--- по запросу рукопожатия (`tnt.admin.app.http.middleware.authorize`),
--- и тот, кому страница ответила бы 401, получает ошибку Centrifugo 101
--- и больше не переподключается. Слоем опознания маршрут не закрыт
--- намеренно: отказ рукопожатия кодом HTTP клиент Centrifugo читает как
--- обрыв и повторяет с отступом без конца.
---
--- Точка — обработчик маршрута вместе со своими сессиями: ядро узнаёт её
--- по `close_all` и, отключая роутер, рвёт сессии и снимает подписку
--- на снимки. Иначе после перечитывания конфигурации прежний узел
--- Centrifugo публиковал бы обзор в пустоту до конца процесса.

local centrifugo = require('tnt.centrifugo')

local log = require('tnt.log').new('tnt.admin')

local authorize = require('tnt.admin.app.http.middleware.authorize')
local overview = require('tnt.admin.app.services.overview')

local Module = {}

--- Путь точки: тот, что клиенты Centrifugo берут по умолчанию.
Module.PATH = '/connection/websocket'

--- Канал обзора: публикация в нём — тот же обзор, что `GET /api/v1/overview`.
Module.CHANNEL = 'overview'

--- Предел соединений точки.
---
--- Панель смотрят операторы, и сотни вкладок — предел с большим запасом.
--- Без предела гость держал бы файберы узла: отказанный `connect`
--- соединения не рвёт, и оно живёт до срока connect.
Module.MAX_CONNECTIONS = 256

--- Собирает точку толчка над источниками.
---
--- Без извещения о новых снимках точки нет: подписанный браузер ждал бы
--- толчков, которых не будет, и перестал бы обновлять страницу.
---@param source TntAdminSource
---@return TntKernelEndpoint|nil
function Module.new(source)
    local updates = source.updates

    if updates == nil then
        return nil
    end

    --- Номер обхода, чей обзор разослан последним.
    ---@type integer|nil
    local published = nil

    --- Отписка от извещения; пусто — подписки ещё нет.
    ---@type fun()|nil
    local cancel = nil

    --- Остановлена ли точка: после остановки подписка не заводится.
    local stopped = false

    local hub = centrifugo.new({
        -- Личность решает здесь только, пускать ли: канал у панели один
        -- на всех, адресных сообщений у неё нет, и пользователь Centrifugo
        -- ей не нужен. Отказ пустотой узел Centrifugo отвечает ошибкой 101
        -- «unauthorized» — той, которую клиент читает как отказ во входе.
        connect = function(client)
            if authorize.identify(source, client.request) == nil then
                return nil
            end

            return {}
        end,

        -- Канал один, и право на него — вход: обзор показывает то же,
        -- что страница обзора, а её видит всякий вошедший. Нынешний обзор
        -- уходит в ответе на подписку: клиенту не нужно ни ждать
        -- следующего обхода, ни спрашивать API отдельно.
        subscribe = function(_, channel)
            if channel ~= Module.CHANNEL then
                return nil, centrifugo.error(centrifugo.ERRORS.UNKNOWN_CHANNEL)
            end

            return { data = overview.of(source) }
        end,
    })

    --- Публикует обзор, если снимок новый.
    ---
    --- Извещение приходит и без нового обхода: наблюдатель события отдаёт
    --- последнее значение сразу, как его завели. Номер обхода отличает
    --- новый снимок от разосланного, и подписчик не получает один обзор
    --- дважды. Отказ пишется в журнал: извещение зовёт наблюдатель,
    --- и брошенное в нём не дошло бы ни до кого.
    local function publish()
        local collected, current = pcall(overview.of, source)

        if not collected then
            log.error(
                'обзор кластера не собран, толчок не ушёл: {err}',
                { err = tostring(current) }
            )

            return
        end

        local generation = current.cluster.generation

        if generation == published then
            return
        end

        local sent, err = hub:publish(Module.CHANNEL, current)

        if sent == nil then
            log.warn('обзор кластера не опубликован: {err}', { err = err })

            return
        end

        published = generation
    end

    local handle = hub:handler({ max_connections = Module.MAX_CONNECTIONS })

    return {
        -- Подписка на снимки заводится с первым рукопожатием, а не
        -- на сборке: к узлу, где панель никто не открывал, обзор
        -- не собирается на каждый обход, а сборка, сорвавшаяся после
        -- маршрутов, не оставляет наблюдателя, которого некому снять.
        handler = function(request)
            if cancel == nil and not stopped then
                cancel = updates(publish)
            end

            return handle(request)
        end,

        -- Коды ядра — коды WebSocket (1001, 1012), а у Centrifugo свои:
        -- сессии рвутся его «shutdown» 3001, и клиент переподключается
        -- к тому, что встало на место прежнего роутера.
        close_all = function()
            stopped = true

            if cancel ~= nil then
                local release = cancel

                cancel = nil
                release()
            end

            return hub:stop()
        end,
    }
end

return Module
