--- Настройки панели: свой `config/admin.lua`, файл приложения и раздел роли.
---
--- Панель настраивается тем же способом, что и само приложение: файлом
--- в `config/`, который возвращает функцию от окружения. Порт, имя
--- сервера и состав источников живут рядом с остальными настройками
--- приложения, а значения приходят из окружения — из `.env` на машине
--- разработчика и из переменных на боевом узле.
---
--- Читаются три слоя, каждый следующий сильнее: `config/admin.lua`
--- самого пакета (умолчания и переменные окружения), `config/admin.lua`
--- приложения — если оно захотело сказать своё, — и раздел `roles_cfg`
--- роли. Сливает их `tnt-config`: словари — вглубь, `null` значения
--- не затирает.
---
---     -- config/admin.lua
---     ---@param env TntEnv
---     return function(env)
---         return {
---             listen = env('ADMIN_LISTEN', '127.0.0.1:8081'),
---             sources = { audit = env.bool('ADMIN_AUDIT', true) },
---         }
---     end
---
--- Раздел `roles_cfg` роли остаётся и кладётся поверх файла: то, что
--- задано конфигурацией кластера, сильнее того, что собрано на узле
--- из окружения, — иначе узел с забытой переменной тихо отвечал бы
--- не тем, что записано в кластере.
---
--- Файла нет — панель работает на умолчаниях: своего сервера не
--- поднимает и встаёт на сервер `admin` у `roles.httpd`.

local config = require('tnt.config')
local external = require('tnt.external')
local must = require('tnt.must')

--- Отказ без места вызова: текст уходит оператору в alerts конфигурации.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Файл настроек приложения: модуль `config/admin.lua` в его каталоге.
Module.SECTION = 'config.admin'

--- Свои умолчания: `config/admin.lua` внутри пакета.
---
--- Именем модуля, а не путём: каталог пакета зависит от того, куда его
--- поставил рок, а имя модуля — нет.
Module.OWN_SECTION = 'tnt.admin.config.admin'

--- Имя сервера `roles.httpd`, на который панель встаёт без настройки.
---
--- Не `default`: там обычно стоит приложение, и молчаливое умолчание
--- отняло бы у него обработчик при первом же включении панели.
Module.DEFAULT_SERVER = 'admin'

--- Поля настроек — и в файле приложения, и в разделе роли.
---
--- Незнакомое поле — отказ: настройка с опечаткой иначе просто
--- не применилась бы, а оператор узнал бы об этом по пустой панели.
local FIELDS = {
    listen = '?not_empty',
    server = '?not_empty',
    watch = {
        '?options',
        {
            login = '?not_empty',
            password = '?string',
            interval = '?positive',
            timeout = '?positive',
            connect_timeout = '?positive',
        },
    },
    actions = {
        '?options',
        {
            login = '?not_empty',
            password = '?string',
            timeout = '?positive',
        },
    },
    sources = {
        '?options',
        {
            snapshot = '?boolean',
            issues = '?boolean',
            suggestions = '?boolean',
            filter = '?boolean',
            audit = '?boolean',
            audit_verify = '?boolean',
            updates = '?boolean',
        },
    },
}

--- Окружение узла: из него собираются значения настроек.
---@return TntEnv
function Module.env()
    return require('tnt.env')
end

--- Файл настроек по имени модуля: своего у пакета либо приложения.
---
--- Пустота, а не бросок: приложение вправе не настраивать панель вовсе,
--- и тогда она работает на умолчаниях пакета.
---@param name string Имя модуля, например config.admin
---@return any|nil
function Module.section(name)
    local ok, loaded = pcall(require, name)

    if not ok then
        return nil
    end

    return loaded
end

--- Средства снаружи: окружение и файл настроек приложения.
---
--- Внешней зависимостью, потому что проверки идут без приложения рядом:
--- каталога `config/` у пакета нет и быть не может.
local source = external.install(Module, { env = Module.env, section = Module.section })

--- Как файл настроек зовётся в отказе: путь, по которому его искать.
---
--- Свой файл пакета зовётся именем модуля: искать `config/admin.lua`
--- в каталоге приложения оператор пошёл бы зря.
---@param name string Имя модуля файла настроек
---@return string
local function named(name)
    if name == Module.OWN_SECTION then
        return name
    end

    return 'config/admin.lua'
end

--- Читает один файл настроек: функцию от окружения и её ответ.
---
--- Файла нет — пусто: приложение вправе панель не настраивать вовсе,
--- а свой файл пакета на месте всегда.
---@param name string Имя модуля файла настроек
---@return table
function Module.from_file(name)
    local builder = source().section(name)

    if builder == nil then
        return {}
    end

    if type(builder) ~= 'function' then
        fail(('%s должен вернуть функцию от окружения'):format(named(name)))
    end

    local ok, built = pcall(builder, source().env())

    if not ok then
        fail(('%s отказал: %s'):format(named(name), tostring(built)))
    end

    if type(built) ~= 'table' then
        fail(
            ('%s должен вернуть таблицу настроек, а вернул %s'):format(
                named(name),
                type(built)
            )
        )
    end

    local complaint = must.explain.options(built, named(name), FIELDS)

    if complaint ~= nil then
        fail(complaint)
    end

    return built
end

--- Читает настройки панели.
---
--- Порядок: умолчания, файл приложения, раздел роли. Каждый следующий
--- сильнее предыдущего.
---@param cfg table|nil Раздел `roles_cfg` роли
---@return table settings
function Module.read(cfg)
    local given = cfg or {}
    local complaint = must.explain.options(given, 'tnt.admin', FIELDS)

    if complaint ~= nil then
        fail(complaint)
    end

    -- Свои умолчания читаются первыми, настройки приложения — поверх них.
    -- Слои сливаются вглубь: у `sources` смысл поля — «показывать ли
    -- источник», и раздел кластера, назвавший один источник, не стирает
    -- остальные, а `null` раздела (`listen: ~`) значит «не сказано»
    -- и заданного файлом не затирает.
    local layers = config.new(Module.from_file(Module.OWN_SECTION), Module.from_file(Module.SECTION), given)

    return layers:all()
end

--- Настройки роли в том виде, в каком их читает ядро.
---
--- Ядро берёт свой раздел `http` из настроек роли, а оператор пишет порт
--- и сервер в `config/admin.lua`: здесь одно превращается в другое,
--- и дальше применение идёт обычным ходом ядра.
---
--- Имя сервера ставится только там, где своего порта нет: названные
--- вместе, порт и сервер — отказ ядра, и умолчание, приписанное
--- к заданному порту, отказывало бы за оператора, который ничего
--- такого не писал.
---@param settings table Прочитанные настройки панели
---@param error_view fun(err: TntError, settings: TntErrorSettings): table Вид тела отказа
---@return table
function Module.role_cfg(settings, error_view)
    return {
        -- Обход кластера панель заводит сама, когда ей дали учётку
        -- наблюдателя (`tnt.admin.app.services.watch`).
        watch = settings.watch,
        -- Действия над кластером идут под своей учёткой: смотреть
        -- и менять — разные права (`tnt.admin.app.services.acting`).
        actions = settings.actions,
        http = {
            listen = settings.listen,
            server = settings.listen == nil and (settings.server or Module.DEFAULT_SERVER) or nil,
            -- Вид отказа панели, а не приложения: её страницы и её JS
            -- читают одно тело, и настройка соседа его не меняет.
            error_view = error_view,
        },
        sources = settings.sources,
    }
end

--- Какие источники выключены настройкой: имя → да.
---@param settings table
---@return table<string, boolean>
function Module.disabled(settings)
    local disabled = {}

    for field, allowed in pairs(settings.sources or {}) do
        if allowed == false then
            disabled[field] = true
        end
    end

    return disabled
end

return Module
