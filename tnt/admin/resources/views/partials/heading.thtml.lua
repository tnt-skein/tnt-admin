{{-- Заголовок раздела: название, пояснение и место под кнопки отбора.

     Поля: `title` — заголовок, `note` — пояснение, `aside` — готовая
     разметка справа (её собирает страница). --}}
<div class="d-flex flex-wrap align-items-center justify-content-between gap-2 mb-3">
    <div>
        <h1 class="h4 mb-0">{{ title }}</h1>
        @if (note ~= nil)
        <p class="text-body-secondary small mb-0">{{ note }}</p>
        @endif
    </div>
    @if (aside ~= nil)
    <div class="d-flex flex-wrap gap-2">{!! aside !!}</div>
    @endif
</div>
