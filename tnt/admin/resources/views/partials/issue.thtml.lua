{{-- Находка списком: что не так, где и насколько важно.

     Поля: `issue` — находка, `advice` — подсказки по этому узлу. --}}
<li class="list-group-item">
    <div class="d-flex gap-3 align-items-start">
        @include('partials.dot', {
            tone = format.level_tone(issue.level),
            blink = issue.level == 'critical',
        })
        <div class="flex-grow-1">
            <p class="mb-1">{{ issue.message }}</p>
            <p class="small text-body-secondary mb-0">
                <span class="font-monospace">{{ issue.server or issue.replicaset or 'кластер' }}</span>
                · {{ issue.rule or '' }}
            </p>
        </div>
        <span class="badge text-bg-{{ format.level_tone(issue.level) }}">{{ format.level(issue.level) }}</span>
    </div>

    @if (advice ~= nil and #advice > 0)
    <div class="d-flex flex-wrap gap-2 mt-2 ms-4 ps-2">
        @for (_, suggestion in ipairs(advice))
        @include('partials.action-form', { suggestion = suggestion })
        @endfor
    </div>
    @endif
</li>
