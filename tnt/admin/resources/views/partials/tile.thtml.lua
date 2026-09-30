{{-- Плитка сводки: число и о чём оно.

     Поля: `title`, `value`, `tone` — цвет числа, `note` — подпись. --}}
<div class="col-6 col-lg-3">
    <div class="card h-100">
        <div class="card-body py-3">
            <p class="text-body-secondary small mb-1">{{ title }}</p>
            <p class="h3 mb-0 text-{{ tone or 'body' }}">{{ value }}</p>
            @if (note ~= nil)
            <p class="small text-body-secondary mb-0 mt-1">{{ note }}</p>
            @endif
        </div>
    </div>
</div>
