--- Проверяет, что упакованная панель не отстала от своих исходных файлов.
---
--- Модуль собирается инструментом, а правится каталог: забыть пересобрать
--- легко, и тогда кластер отдаёт вчерашнюю панель, о чём никто не узнает
--- до первой жалобы.

local fio = require('fio')

local files = dofile('tools/files.lua')

local SOURCE_DIR = 'panel'
local BUNDLE_PATH = 'tnt/admin/public/bundle.lua'

local bundle = assert(loadfile(BUNDLE_PATH))()
local stale = {}
local missing = {}

for _, name in ipairs(files.list(SOURCE_DIR)) do
    if bundle[name] == nil then
        table.insert(missing, name)
    elseif bundle[name] ~= files.read(fio.pathjoin(SOURCE_DIR, name)) then
        table.insert(stale, name)
    end

    bundle[name] = nil
end

local extra = {}
for name in pairs(bundle) do
    table.insert(extra, name)
end

table.sort(stale)
table.sort(missing)
table.sort(extra)

if #stale == 0 and #missing == 0 and #extra == 0 then
    print('Упакованная панель совпадает с исходными файлами.')
    os.exit(0)
end

for _, name in ipairs(missing) do
    print(('Файл %s есть в панели, но не упакован.'):format(name))
end

for _, name in ipairs(stale) do
    print(('Файл %s упакован в прежнем виде.'):format(name))
end

for _, name in ipairs(extra) do
    print(('Файл %s упакован, но из панели удалён.'):format(name))
end

print('Выполните `make panel`.')
os.exit(1)
