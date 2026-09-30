--- Собирает описание API панели `docs/api/panel.yaml` из её кода.
---
--- Документ OpenAPI собирает `tnt-openapi` (`Api.document`) из маршрутов
--- панели, форм `tnt-data` и слов операций (`tnt.admin.app.http.openapi`),
--- а здесь он только записывается файлом с постоянным порядком ключей
--- (`tools/lib/api_document.lua`). Маршрут без описания и описание без
--- маршрута — отказ сборки: файл тогда не трогается.
---
--- Перед записью текст разбирается обратно и сличается с документом:
--- запись своя, и ошибка в ней иначе уехала бы в файл, который сверка
--- потом читает как договор.
---
--- Запуск: tarantool tools/build_api_spec.lua [путь]
--- Путь по умолчанию — docs/api/panel.yaml.

local yaml = require('yaml')

local api_document = require('tools.lib.api_document')

local files = dofile('tools/files.lua')

local PATH = arg[1] or api_document.PATH

--- Панель и её описание — из исходников, а не из `.rocks`: установленная
--- копия пакета знала бы только вчерашние формы и слова.
local panels = dofile('test/helper.lua')
local panel_http = panels.load('tnt.admin.app.http.panel')
local api = panels.testing.module('tnt.admin.app.http.openapi')

local document, problems = api.document(panel_http.new({}))

if document == nil then
    print(
        'Описание API не собрано: маршруты панели расходятся с описанием операций.'
    )

    for _, problem in ipairs(problems or {}) do
        print('  ' .. problem)
    end

    os.exit(1)
end

local text = api_document.render(document)
local drift = api_document.differences(yaml.decode(text), document)

if drift[1] ~= nil then
    error('запись описания разошлась с документом: ' .. table.concat(drift, '; '))
end

files.write(PATH, text)

local operations = 0

for _, item in pairs(document.paths) do
    for key in pairs(item) do
        operations = operations + (key ~= 'servers' and 1 or 0)
    end
end

print(('Описание API собрано: %s, операций %d.'):format(PATH, operations))
