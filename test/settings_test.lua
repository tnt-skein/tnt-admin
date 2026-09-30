--- Тесты настроек панели: файл приложения, окружение и раздел роли.
---
--- Настоящего `config/admin.lua` здесь нет: каталог настроек живёт
--- у приложения, а пакет обязан работать и с ним, и без него.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.services.settings')

---@type any
local settings

--- Вид тела отказа: раздел роли обязан донести его до ядра как есть.
local VIEW = function()
    return {}
end

--- Средства настроек: файлы настроек и окружение.
---@param builder any Что отдаёт файл приложения `config/admin.lua`
---@param values table<string, any>|nil Значения окружения
---@param own any Что отдаёт свой файл пакета; пусто — его нет
local function given(builder, values, own)
    settings._set_source({
        section = function(name)
            if name == settings.OWN_SECTION then
                return own
            end

            return builder
        end,
        env = function()
            return setmetatable({}, {
                __call = function(_, name, default)
                    local value = (values or {})[name]

                    if value == nil then
                        return default
                    end

                    return value
                end,
            })
        end,
    })
end

g.before_each(function()
    settings = helper.load('tnt.admin.app.services.settings')
end)

g.after_each(function()
    helper.unload()
end)

g.test_without_a_file_defaults_are_used = function()
    -- Приложение панелью не настраивало: она встаёт на сервер admin
    -- и своего порта не поднимает. Имя сервера приписывает раздел роли
    -- для ядра: у заданного порта имени сервера быть не должно.
    given(nil)

    local read = settings.read()

    t.assert_equals(read, {})
    t.assert_equals(settings.role_cfg(read, VIEW).http.server, 'admin')
    t.assert_equals(settings.role_cfg(read, VIEW).http.listen, nil)

    -- Файла нет — пустая таблица, а не пустота: чтение одного файла
    -- обещает таблицу и тому, кто зовёт его мимо `read`.
    t.assert_equals(settings.from_file(settings.SECTION), {})
    t.assert_equals(settings.from_file(settings.OWN_SECTION), {})
end

g.test_an_own_port_leaves_the_role_without_a_server_name = function()
    -- Порт и сервер вместе — отказ ядра: умолчание, приписанное
    -- к заданному порту, отказывало бы за оператора, который ничего
    -- такого не писал.
    given(nil)

    local http = settings.role_cfg(settings.read({ listen = '127.0.0.1:8081' }), VIEW).http

    t.assert_equals({ http.listen, http.server }, { '127.0.0.1:8081' })
end

g.test_the_role_section_carries_the_view_of_the_panel = function()
    -- Вид тела отказа панель отдаёт ядру: им ядро рисует и отказы
    -- роутера, и поломки, и настройка соседнего приложения его не меняет.
    given(nil)

    t.assert_is(settings.role_cfg(settings.read(), VIEW).http.error_view, VIEW)
end

g.test_the_file_is_asked_with_the_environment = function()
    -- Настройки собираются из окружения так же, как у приложения:
    -- значения приходят из переменных, умолчания — из файла.
    given(function(env)
        return { listen = env('ADMIN_LISTEN', '127.0.0.1:8081') }
    end, { ADMIN_LISTEN = '0.0.0.0:9090' })

    t.assert_equals(settings.read().listen, '0.0.0.0:9090')
end

g.test_the_default_of_the_file_is_taken_when_the_variable_is_absent = function()
    given(function(env)
        return { listen = env('ADMIN_LISTEN', '127.0.0.1:8081') }
    end)

    t.assert_equals(settings.read().listen, '127.0.0.1:8081')
end

g.test_the_cluster_section_beats_the_file = function()
    -- Забытая на узле переменная не должна тихо отменять то, что
    -- записано в конфигурации кластера.
    given(function()
        return { server = 'из файла' }
    end)

    t.assert_equals(settings.read({ server = 'из кластера' }).server, 'из кластера')
end

g.test_sources_of_the_file_and_of_the_cluster_are_merged = function()
    -- Раздел кластера, назвавший один источник, не стирает остальные:
    -- у поля смысл «показывать ли», а не «вот весь список».
    given(function()
        return { sources = { audit = false, issues = false } }
    end)

    local read = settings.read({ sources = { issues = true } })

    t.assert_equals(read.sources, { audit = false, issues = true })
end

g.test_a_null_of_the_cluster_section_keeps_what_the_file_says = function()
    -- `listen: ~` в разделе роли значит «не сказано», а не «порта нет»:
    -- иначе раздел, где поле оставили пустым, отнимал бы у панели порт.
    given(function()
        return { listen = '127.0.0.1:8081', sources = { audit = false } }
    end)

    local read = settings.read({ listen = box.NULL, sources = { audit = box.NULL } })

    t.assert_equals(read.listen, '127.0.0.1:8081')
    t.assert_equals(read.sources, { audit = false })
end

g.test_a_disabled_source_is_named = function()
    given(function()
        return { sources = { audit = false, issues = true } }
    end)

    t.assert_equals(settings.disabled(settings.read()), { audit = true })
end

g.test_without_sources_nothing_is_disabled = function()
    given(nil)

    t.assert_equals(settings.disabled(settings.read()), {})
end

g.test_an_unknown_field_of_the_cluster_section_is_refused = function()
    given(nil)

    t.assert_error_msg_contains('ключа «serevr» нет', settings.read, { serevr = 'admin' })
end

g.test_an_unknown_field_of_the_file_is_refused = function()
    -- Опечатка в файле приложения иначе просто не применилась бы,
    -- а оператор узнал бы об этом по пустой панели.
    given(function()
        return { lisen = '8081' }
    end)

    t.assert_error_msg_contains('config/admin.lua: ключа «lisen» нет', settings.read)
end

g.test_a_file_that_is_not_a_function_is_refused = function()
    given({ listen = '8081' })

    t.assert_error_msg_contains('config/admin.lua должен вернуть функцию', settings.read)
end

g.test_a_file_that_returns_not_a_table_is_refused = function()
    given(function()
        return 'восемь тысяч'
    end)

    t.assert_error_msg_contains(
        'должен вернуть таблицу настроек, а вернул string',
        settings.read
    )
end

g.test_a_broken_file_is_named_in_the_refusal = function()
    -- Отказ обязательной переменной окружения выглядит именно так,
    -- и оператор должен увидеть, какой файл его дал.
    given(function()
        error('нет переменной ADMIN_LISTEN')
    end)

    t.assert_error_msg_contains('config/admin.lua отказал: ', settings.read)
end

g.test_the_real_seam_looks_for_the_file_of_the_application = function()
    -- Умолчание шва: приложения рядом нет, и файла настроек тоже —
    -- панель обязана работать, а не падать на его отсутствии.
    t.assert_equals(settings.section('такого.раздела.нет'), nil)
end

g.test_the_real_seam_gives_the_environment = function()
    t.assert_equals(settings.env(), require('tnt.env'))
end

g.test_the_file_of_the_application_beats_the_defaults_of_the_package = function()
    -- Свой файл пакета — умолчания: порт, имя сервера, состав источников.
    -- Приложение вправе сказать своё, и сказанное им сильнее.
    given(
        function()
            return { listen = '0.0.0.0:9090' }
        end,
        nil,
        function()
            return { server = 'admin', listen = '127.0.0.1:8081' }
        end
    )

    t.assert_equals(settings.read(), { server = 'admin', listen = '0.0.0.0:9090' })
end

g.test_the_role_section_beats_both_files = function()
    -- То, что записано в конфигурации кластера, сильнее собранного
    -- на узле: иначе узел с забытой переменной тихо отвечал бы не тем,
    -- что записано в кластере.
    given(
        function()
            return { listen = '0.0.0.0:9090' }
        end,
        nil,
        function()
            return { server = 'admin' }
        end
    )

    t.assert_equals(settings.read({ listen = '127.0.0.1:7070' }).listen, '127.0.0.1:7070')
end

g.test_the_defaults_of_the_package_are_named_in_the_refusal_by_the_module = function()
    -- Искать `config/admin.lua` в каталоге приложения из-за опечатки
    -- в файле пакета оператор пошёл бы зря.
    given(nil, nil, function()
        return { lisen = '8081' }
    end)

    t.assert_error_msg_contains('tnt.admin.config.admin: ключа «lisen» нет', settings.read)
end

g.test_the_real_external_requires_the_file_by_its_module_name = function()
    -- Умолчание внешней зависимости: файл настроек подключается по имени
    -- модуля — свой у пакета есть всегда, а файла приложения на узле
    -- может не быть вовсе.
    settings._set_source(nil)

    t.assert_is(settings.section(settings.OWN_SECTION), require(settings.OWN_SECTION))
    t.assert_equals(settings.section('config.нет-такого'), nil)
end

g.test_the_watcher_account_travels_to_the_role_section = function()
    -- Учётку наблюдателя читает провайдер панели: он и заводит обход.
    given(nil, nil, function()
        return { watch = { login = 'health', password = 'секрет' } }
    end)

    local role = settings.role_cfg(settings.read({ watch = { interval = 5 } }), VIEW)

    t.assert_equals(role.watch, { login = 'health', password = 'секрет', interval = 5 })
end

g.test_a_wrong_field_of_the_watcher_is_refused = function()
    -- Опечатка в разделе обхода иначе прошла бы молча, а оператор узнал
    -- бы о ней по пустому кластеру в панели.
    given(nil)

    t.assert_error_msg_contains('ключа «logni» нет', settings.read, { watch = { logni = 'health' } })
    t.assert_error_msg_contains('tnt.admin.watch.interval', settings.read, { watch = { interval = -1 } })
end
