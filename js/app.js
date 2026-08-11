let scheduleData = [];
let biosData = [];
let bioMap = {};
let awardsData = [];
let awardMap = {};
let allTracks = new Set();
let allTimeSlotsData = [];
let excursionsData = [];
let committeeData = {};
const seenSlotKeys = new Set();
let sessionCalendarData = {};

const trackMap = {
    'General Industry Studies':                                          { short: 'General Industry',          color: '#E69F00' },
    'Health Care Systems, Biotechnology, and Pharmaceuticals':           { short: 'Health Care & Pharma',      color: '#56B4E9' },
    'Innovation, Entrepreneurship, and AI-Driven Transformation':        { short: 'Innovation & AI',           color: '#CC79A7' },
    'Labor Markets, Organizations, and the Future of Work':              { short: 'Labor & Work',              color: '#F0E442' },
    'Operations, Supply Chain, and AI-Enhanced Industry 4.0':            { short: 'Operations & Supply Chain', color: '#0072B2' },
    'Public Policy and Global Competitiveness':                          { short: 'Public Policy',             color: '#D55E00' },
    'Sustainable Innovation, Energy, and Mobility':                      { short: 'Sustainability & Energy',   color: '#009E73' },
    'Cross-Track':                                                        { short: 'Cross-Track',               color: '#5C4D7D' }
};

// Data loading helpers. These produce useful errors for missing files and
// prevent an optional auxiliary file from taking down the schedule.
function asArray(value, label) {
    if (Array.isArray(value)) return value;
    console.warn(`${label} should be a JSON array; using an empty array instead.`, value);
    return [];
}

async function fetchJson(path, { optional = false, fallback = null } = {}) {
    try {
        const response = await fetch(path, { cache: 'no-store' });
        if (!response.ok) {
            throw new Error(`${path} returned HTTP ${response.status}`);
        }
        const text = await response.text();
        try {
            return JSON.parse(text);
        } catch (error) {
            throw new Error(`${path} is not valid JSON: ${error.message}`);
        }
    } catch (error) {
        if (optional) {
            console.warn(error.message);
            return fallback;
        }
        throw error;
    }
}

// Load data
Promise.all([
    fetchJson('json/schedule_data.json'),
    fetchJson('json/bios_data.json'),
    fetchJson('json/awards_data.json'),
    fetchJson('json/excursions_data.json', { optional: true, fallback: [] }),
    fetchJson('json/committee_data.json', { optional: true, fallback: {} })
])
    .then(([data, bios, awards, excursions, committee]) => {
        scheduleData = asArray(data, 'schedule_data.json');
        biosData = asArray(bios, 'bios_data.json');
        awardsData = asArray(awards, 'awards_data.json');
        excursionsData = asArray(excursions, 'excursions_data.json');
        committeeData = committee && typeof committee === 'object' && !Array.isArray(committee)
            ? committee
            : {};

        if (!Array.isArray(data)) {
            throw new Error('json/schedule_data.json must contain a top-level JSON array');
        }
        renderCommittee();
        buildBioMap();
        buildAwardMap();

        data.forEach(item => {
            if (item.category) allTracks.add(item.category);
            if (item.time_slot && item.day) {
                const slotKey = `${item.time_slot}__${item.day}`;
                if (!seenSlotKeys.has(slotKey)) {
                    seenSlotKeys.add(slotKey);
                    const timeLabel = item.start_time && item.end_time
                        ? `${item.day.substring(0,3)} ${formatTime(item.start_time)} – ${formatTime(item.end_time)}`
                        : `${item.day} ${item.time_slot}`;
                    allTimeSlotsData.push({
                        slot: item.time_slot,
                        day: item.day,
                        label: timeLabel,
                        start_time: item.start_time,
                        end_time: item.end_time,
                        order: item.time_order
                    });
                }
            }
        });

        // Populate track dropdown
        const trackFilter = document.getElementById('trackFilter');
        Array.from(allTracks).sort().forEach(track => {
            const exists = Array.from(trackFilter.options).some(option => option.value === track);
            if (exists) return;
            const option = document.createElement('option');
            option.value = track;
            option.textContent = trackMap[track] ? trackMap[track].short : track;
            trackFilter.appendChild(option);
        });

        trackFilter.addEventListener('change', function() {
            const wrapper = this.closest('.track-select-wrapper');
            const info = trackMap[this.value];
            wrapper.style.setProperty('--track-color', info ? info.color : '#e5e5e5');
        });

        // Populate time slot dropdown (all slots initially)
        updateTimeSlotDropdown('');

        renderSchedule();
        renderSpeakers();
        renderAwards();
        attachEventListeners();
    })
    .catch(err => {
        console.error('ISA schedule initialisation failed:', err);
        document.getElementById('schedule').innerHTML =
            `<div class="no-results"><h2>Error loading schedule</h2><p>${escapeHtml(err.message)}</p><p>Open the browser console for the full error and file name.</p></div>`;
    });

function attachEventListeners() {
    document.querySelectorAll('.view-btn').forEach(btn => {
        btn.addEventListener('click', () => switchView(btn.getAttribute('data-view')));
    });

    document.getElementById('search').addEventListener('input', () => { updateFilterIndicators(); renderSchedule(); });
    document.getElementById('timeSlotFilter').addEventListener('change', () => { updateFilterIndicators(); renderSchedule(); });
    document.getElementById('trackFilter').addEventListener('change', () => { updateFilterIndicators(); renderSchedule(); });
    document.getElementById('typeFilter').addEventListener('change', () => { updateFilterIndicators(); renderSchedule(); });
    document.getElementById('expandAll').addEventListener('click', () => expandCollapseAll(true));
    document.getElementById('collapseAll').addEventListener('click', () => expandCollapseAll(false));
    document.getElementById('resetFilters').addEventListener('click', resetAllFilters);

    document.querySelectorAll('.day-tab').forEach(tab => {
        tab.addEventListener('click', function() {
            document.querySelectorAll('.day-tab').forEach(t => t.classList.remove('active'));
            this.classList.add('active');
            updateTimeSlotDropdown(this.getAttribute('data-day'));
            updateFilterIndicators();
            renderSchedule();
        });
    });

    const mobileToggle = document.getElementById('mobileFilterToggle');
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebarOverlay');
    mobileToggle.addEventListener('click', () => {
        sidebar.classList.add('mobile-open');
        overlay.classList.add('show');
    });
    overlay.addEventListener('click', () => {
        sidebar.classList.remove('mobile-open');
        overlay.classList.remove('show');
    });
}

function expandCollapseAll(expand) {
    document.querySelectorAll('.session-group').forEach(s => {
        s.classList.toggle('expanded', expand);
    });
}

function isSpecial(type) {
    return type === 'special_session' || type === 'plenary';
}

function itemMatchesSearch(item, searchTerm) {
    return (item.session_name && item.session_name.toLowerCase().includes(searchTerm)) ||
        (item.title        && item.title.toLowerCase().includes(searchTerm))        ||
        (item.authors      && item.authors.toLowerCase().includes(searchTerm))      ||
        (item.abstract     && item.abstract.toLowerCase().includes(searchTerm))     ||
        (item.moderator    && item.moderator.toLowerCase().includes(searchTerm))     ||
        (item.discussant   && item.discussant.toLowerCase().includes(searchTerm))   ||
        (item.session_chair && item.session_chair.toLowerCase().includes(searchTerm)) ||
        (item.type === 'event' && getExcursionSearchText(item.session_name).includes(searchTerm));
}

function renderSchedule() {
    const searchTerm   = document.getElementById('search').value.toLowerCase();
    const dayFilter    = document.querySelector('.day-tab.active').getAttribute('data-day');
    const slotFilter   = document.getElementById('timeSlotFilter').value;
    const trackFilter  = document.getElementById('trackFilter').value;
    const typeFilter   = document.getElementById('typeFilter').value;

    // Apply non-search filters at the item level
    const nonSearchFiltered = scheduleData.filter(item => {
        const dayMatch  = !dayFilter   || item.day === dayFilter;
        const slotMatch = !slotFilter  || item.time_slot === slotFilter;
        const trackMatch = !trackFilter || item.category === trackFilter;
        const typeMatch = !typeFilter  ||
            (typeFilter === 'paper'   && (item.type === 'paper' || item.type === 'panel' || item.type === 'self_organized_panel')) ||
            (typeFilter === 'special' && isSpecial(item.type)) ||
            (typeFilter === 'event'   && item.type === 'event');
        return dayMatch && slotMatch && trackMatch && typeMatch;
    });

    // Group by session, then apply search at the session level so that
    // matching any paper in a session shows the whole session
    const sessionMap = {};
    nonSearchFiltered.forEach(item => {
        const key = `${item.session_id}_${item.time_slot}`;
        if (!sessionMap[key]) sessionMap[key] = [];
        sessionMap[key].push(item);
    });

    const filtered = [];
    Object.values(sessionMap).forEach(items => {
        if (!searchTerm || items.some(item => itemMatchesSearch(item, searchTerm))) {
            filtered.push(...items);
        }
    });

    // Sort chronologically
    filtered.sort((a, b) => {
        if (a.time_order !== b.time_order) return a.time_order - b.time_order;
        const sa = String(a.session_id), sb = String(b.session_id);
        return sa.localeCompare(sb);
    });

    // Group by session
    const sessions = {};
    filtered.forEach(item => {
        const key = `${item.session_id}_${item.time_slot}`;
        if (!sessions[key]) {
            sessions[key] = {
                session_id:    item.session_id,
                session_name:  item.session_name,
                time_slot:     item.time_slot,
                room:          item.room,
                date:          item.date,
                day:           item.day,
                start_time:    item.start_time,
                end_time:      item.end_time,
                time_order:    item.time_order,
                category:      item.category,
                type:          item.type,
                session_chair: item.session_chair || null,
                discussant:    item.discussant    || null,
                papers: []
            };
        }
        sessions[key].papers.push(item);
    });

    const scheduleDiv = document.getElementById('schedule');
    const sessionList = Object.values(sessions);

    if (sessionList.length === 0) {
        scheduleDiv.innerHTML = '<div class="no-results"><h2>No results found</h2><p>Try adjusting your search or filters</p></div>';
        document.getElementById('sessionCount').textContent = '0';
        document.getElementById('paperCount').textContent = '0';
        return;
    }

    sessionCalendarData = {};
    let html = '';
    let totalSessions = 0;
    let totalPapers = 0;

    sessionList.forEach(session => {
        const isEvent = session.type === 'event';
        const isActivity = session.type === 'activity';
        const isPanel = session.type === 'panel';
        const special = isSpecial(session.type);

        if (!isEvent && !isActivity) {
            totalSessions++;
            if (!special && !isPanel && session.session_name !== 'Award Winners Panel') {
                totalPapers += session.papers.filter(p => p.type === 'paper' || p.type === 'self_organized_panel').length;
            }
        }

        const timeStr = session.start_time && session.end_time
            ? `${formatTime(session.start_time)} – ${formatTime(session.end_time)}`
            : session.time_slot;

        // Render social events and other programme activities as banner cards.
        if (isActivity) {
            html += `
            <div class="session-group cat-activity event-card">
                <div class="session-header">
                    <div class="session-meta">
                        <div>
                            <div class="session-title-row">
                                <span class="session-title">${escapeHtml(session.session_name)}</span>
                                <span class="session-badge badge-activity">Activity</span>
                            </div>
                            <div class="session-info">
                                <span>📅 ${session.day}, ${formatDate(session.date)}</span>
                                <span>🕒 ${timeStr}</span>
                                <span>📍 ${session.room || 'TBA'}</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>`;
            return;
        }

        // Social events are tagged separately from papers, panels, plenaries, and special sessions.
        if (isEvent) {
            const excursion = findExcursion(session.session_name);
            if (!excursion) {
                html += `
            <div class="session-group cat-event event-card">
                <div class="session-header">
                    <div class="session-meta">
                        <div>
                            <div class="session-title-row">
                                <span class="session-title">${escapeHtml(session.session_name)}</span>
                                <span class="session-badge badge-event">Social</span>
                            </div>
                            <div class="session-info">
                                <span>📅 ${session.day}, ${formatDate(session.date)}</span>
                                <span>🕒 ${timeStr}</span>
                                <span>📍 ${session.room || 'TBA'}</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>`;
                return;
            }
            const excCalKey = `cal_${String(session.session_id || '').replace(/[^a-zA-Z0-9]/g, '_')}_${(session.time_slot || '').replace(/[^a-zA-Z0-9]/g, '_')}`;
            sessionCalendarData[excCalKey] = session;
            const excCalBtn = `<div style="padding:10px 20px 4px;"><div class="cal-wrapper"><button class="cal-btn" onclick="event.stopPropagation();toggleCalMenu(this,'${excCalKey}')">&#128197; Add to Calendar &#9662;</button><div class="cal-menu" style="display:none"><a href="#" onclick="event.preventDefault();event.stopPropagation();calToGoogle('${excCalKey}')">&#127760; Google Calendar</a><a href="#" onclick="event.preventDefault();event.stopPropagation();calDownloadICS('${excCalKey}')">&#128229; Apple / Outlook (.ics)</a></div></div></div>`;
            html += `
            <div class="session-group cat-event">
                <div class="session-header" onclick="toggleSession(this)">
                    <div class="session-meta">
                        <div>
                            <div class="session-title-row">
                                <span class="session-title">${escapeHtml(session.session_name)}</span>
                                <span class="session-badge badge-event">Excursion</span>
                            </div>
                            <div class="session-info">
                                <span>📅 ${session.day}, ${formatDate(session.date)}</span>
                                <span>🕒 ${timeStr}</span>
                                <span>📍 ${escapeHtml(excursion.meeting_point || session.room || 'TBA')}</span>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="session-papers">
                    ${excCalBtn}${renderExcursionContent(excursion)}
                </div>
            </div>`;
            return;
        }

        const categoryClass = special ? 'cat-special' : getCategoryClass(session.category);

        const badge = session.type === 'plenary'
            ? '<span class="session-badge badge-plenary">Plenary</span>'
            : session.type === 'special_session'
            ? '<span class="session-badge badge-special">Special Session</span>'
            : session.type === 'panel'
            ? '<span class="session-badge badge-panel">Panel</span>'
            : '';

        const isAwp = session.session_name === 'Award Winners Panel';

        const typeLabel = isAwp                               ? '🏆 Award Winners Panel' :
                          session.type === 'plenary'         ? '🎤 Plenary Session' :
                          session.type === 'special_session' ? '🎤 Special Session' :
                          session.type === 'panel'           ? '🗣 Panel' :
                          `📄 ${session.papers.length} paper${session.papers.length !== 1 ? 's' : ''}`;

        const trackInfo = trackMap[session.category];
        const categoryLabel = trackInfo
            ? `<span class="session-category" style="color:${trackInfo.color}">■ ${trackInfo.short}</span>`
            : (session.category ? `<span class="session-category">${escapeHtml(session.category)}</span>` : '');

        const papersHtml = special || isPanel
            ? renderPanelContent(session.papers[0])
            : session.papers.map(renderPaper).join('');

        const chairHtml = !special && !isPanel && session.session_chair
            ? `<div class="session-chair"><strong>Session Chair:</strong> ${escapeHtml(session.session_chair)}</div>`
            : '';

        const discussantHtml = !special && !isPanel && session.discussant
            ? `<div class="session-discussant"><strong>Discussant:</strong> ${escapeHtml(session.discussant)}</div>`
            : '';

        const calKey = `cal_${String(session.session_id || '').replace(/[^a-zA-Z0-9]/g, '_')}_${(session.time_slot || '').replace(/[^a-zA-Z0-9]/g, '_')}`;
        sessionCalendarData[calKey] = session;
        const calBtn = `<div style="padding:10px 20px 4px;"><div class="cal-wrapper"><button class="cal-btn" onclick="event.stopPropagation();toggleCalMenu(this,'${calKey}')">&#128197; Add to Calendar &#9662;</button><div class="cal-menu" style="display:none"><a href="#" onclick="event.preventDefault();event.stopPropagation();calToGoogle('${calKey}')">&#127760; Google Calendar</a><a href="#" onclick="event.preventDefault();event.stopPropagation();calDownloadICS('${calKey}')">&#128229; Apple / Outlook (.ics)</a></div></div></div>`;
        html += `
            <div class="session-group ${categoryClass}">
                <div class="session-header" onclick="toggleSession(this)">
                    <div class="session-meta">
                        <div>
                            <div class="session-title-row">
                                <span class="session-title">${escapeHtml(session.session_name || 'Untitled Session')}</span>
                                ${badge}
                            </div>
                            <div class="session-info">
                                <span>📅 ${session.day}, ${formatDate(session.date)}</span>
                                <span>🕒 ${timeStr}</span>
                                <span>📍 ${session.room || 'TBA'}</span>
                                <span>${typeLabel}</span>
                                ${categoryLabel}
                            </div>
                        </div>
                    </div>
                </div>
                <div class="session-papers">
                    ${calBtn}${chairHtml}${discussantHtml}${papersHtml}
                </div>
            </div>`;
    });

    scheduleDiv.innerHTML = html;
    document.getElementById('sessionCount').textContent = totalSessions;
    document.getElementById('paperCount').textContent = totalPapers;
}

function findExcursion(session_name) {
    return asArray(excursionsData, 'excursions_data.json')
        .find(e => e && e.session_name === session_name) || null;
}

function getExcursionSearchText(session_name) {
    const ex = findExcursion(session_name);
    if (!ex) return '';
    let text = (ex.description || '') + ' ' + (ex.meeting_point || '');
    const timeline = Array.isArray(ex.timeline) ? ex.timeline : [];
    timeline.forEach(item => { text += ' ' + item.activity; });
    const orgs = Array.isArray(ex.organizations) ? ex.organizations : [];
    orgs.forEach(org => {
        text += ' ' + (org.name || '');
        if (typeof org.panel_title === 'string' && org.panel_title.trim()) text += ' ' + org.panel_title;
        const spks = Array.isArray(org.speakers) ? org.speakers : [];
        spks.forEach(s => { text += ' ' + s.name + ' ' + s.role; });
    });
    return text.toLowerCase();
}

function renderExcursionContent(excursion) {
    let html = '';
    const timeline = Array.isArray(excursion.timeline) ? excursion.timeline : [];
    const orgs = Array.isArray(excursion.organizations) ? excursion.organizations : [];

    if (timeline.length > 0) {
        // Integrated view: build a lookup of org details by name
        const orgMap = {};
        orgs.forEach(org => { if (org && org.name) orgMap[org.name] = org; });

        html += `<div><strong>Program</strong>`;
        html += `<table style="margin:0.4em 0 0 0;border-collapse:collapse">`;
        timeline.forEach(item => {
            const timeStr = String(item.time || '');
            const actStr  = String(item.activity || '');
            const org = orgMap[actStr];
            html += `<tr>
                <td style="white-space:nowrap;vertical-align:top;padding:0.2em 1.2em 0.2em 0;font-size:0.9em;color:#555;font-family:monospace">${escapeHtml(timeStr)}</td>
                <td style="padding:0.2em 0;font-size:0.9em;vertical-align:top">`;
            html += `<strong>${escapeHtml(actStr)}</strong>`;
            if (org) {
                const pt = typeof org.panel_title === 'string' ? org.panel_title.trim() : '';
                if (pt) {
                    html += `<div style="font-style:italic;margin-top:0.1em">${escapeHtml(pt)}</div>`;
                }
                const spks = Array.isArray(org.speakers) ? org.speakers : [];
                spks.forEach(s => {
                    html += `<div style="font-size:0.9em;color:#444">${escapeHtml(String(s.name || ''))}, <em>${escapeHtml(String(s.role || ''))}</em></div>`;
                });
            }
            html += `</td></tr>`;
        });
        html += `</table></div>`;
    } else {
        // No timeline: show description and org list (used for excursions without a program)
        if (excursion.description) {
            html += `<div class="panel-description">${escapeHtml(String(excursion.description))}</div>`;
        }
        orgs.forEach(org => {
            if (!org) return;
            html += `<div style="margin-top:0.8em"><strong>${escapeHtml(String(org.name || ''))}</strong>`;
            const pt2 = typeof org.panel_title === 'string' ? org.panel_title.trim() : '';
            if (pt2) {
                html += `<div><em>${escapeHtml(pt2)}</em></div>`;
            }
            const spks = Array.isArray(org.speakers) ? org.speakers : [];
            if (spks.length > 0) {
                html += `<ul style="margin:0.3em 0 0 1em;padding:0">`;
                spks.forEach(s => {
                    html += `<li>${escapeHtml(String(s.name || ''))}, <em>${escapeHtml(String(s.role || ''))}</em></li>`;
                });
                html += `</ul>`;
            }
            html += `</div>`;
        });
    }
    return `<div class="paper">${html}</div>`;
}

function renderPaper(paper) {
    const aw = getAwardForTitle(paper.title);
    const awardBadge = aw
        ? `<span class="award-badge ${aw.rank === 'Winner' ? 'award-badge-winner' : 'award-badge-runnerup'}">${aw.rank === 'Winner' ? '🏆' : '🥈'} ${escapeHtml(aw.rank)}: ${escapeHtml(aw.award)}</span>`
        : '';
    const authorsHtml = paper.authors
        ? escapeHtml(paper.authors).replace(/\*/g, '<sup style="color:#0d6efd;font-size:0.75em;font-weight:600;">*</sup>')
        : '';
    return `
        <div class="paper">
            <div class="paper-title">${escapeHtml(paper.title || 'Untitled')}${awardBadge}</div>
            ${authorsHtml ? `<div class="paper-authors">${authorsHtml}</div>` : ''}
            ${paper.abstract ? `
                <button class="abstract-toggle" onclick="toggleAbstract(this, event)">View Abstract</button>
                <div class="abstract" id="abstract-${paper.id}">${escapeHtml(paper.abstract)}</div>
            ` : ''}
        </div>`;
}

function renderPanelContent(panel) {
    if (!panel) return '';

    // Only plenaries and special sessions link speaker names to biography cards.
    // Concurrent discussion panels use the same layout, with plain text names.
    const allowSpeakerLinks = panel.type === 'plenary' || panel.type === 'special_session';
    const renderPerson = value => allowSpeakerLinks ? renderPanelistLine(value) : escapeHtml(value);

    const mod = panel.moderator && panel.moderator.trim() && panel.moderator.trim() !== 'TBD'
        ? `<div class="panel-moderator"><strong>Moderator:</strong> ${renderPerson(panel.moderator.trim())}</div>`
        : '';

    let panelists = '';
    if (panel.authors && panel.authors.trim() && panel.authors.trim() !== 'TBD') {
        const items = panel.authors.split(/[;\n]+/).map(p => p.trim()).filter(p => p.length > 0);
        const label = panel.type === 'plenary' ? 'Speakers' : panel.type === 'panel' ? 'Panelists' : 'Special Session Speakers';
        panelists = `<div class="panel-panelists"><strong>${label}:</strong><ul>
            ${items.map(p => `<li>${renderPerson(p)}</li>`).join('')}
        </ul></div>`;
    }

    const desc = panel.abstract && panel.abstract.trim() && panel.abstract.trim() !== 'TBD'
        ? `<div class="panel-description"><strong>Description:</strong> ${escapeHtml(panel.abstract.trim())}</div>`
        : '';

    return `<div class="paper">${mod}${panelists}${desc}</div>`;
}

function toggleSession(element) {
    element.parentElement.classList.toggle('expanded');
}

function toggleAbstract(button, event) {
    if (event) {
        event.stopPropagation();
    }

    const abstract = button.nextElementSibling;
    if (!abstract || !abstract.classList.contains('abstract')) {
        return;
    }

    abstract.classList.toggle('visible');
    button.textContent = abstract.classList.contains('visible') ? 'Hide Abstract' : 'View Abstract';
}

function formatTime(timeStr) {
    if (!timeStr) return '';
    const [hours, minutes] = timeStr.split(':');
    const h = parseInt(hours);
    const period = h >= 12 ? 'PM' : 'AM';
    const hour12 = h === 0 ? 12 : h > 12 ? h - 12 : h;
    return `${hour12}:${minutes} ${period}`;
}

function formatDate(dateStr) {
    if (!dateStr) return '';
    const date = new Date(dateStr + 'T00:00:00');
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function updateTimeSlotDropdown(selectedDay) {
    const timeSlotFilter = document.getElementById('timeSlotFilter');
    const currentSlot = timeSlotFilter.value;

    timeSlotFilter.innerHTML = '<option value="">All Time Slots</option>';

    const slots = selectedDay
        ? allTimeSlotsData.filter(ts => ts.day === selectedDay)
        : allTimeSlotsData;

    slots.slice().sort((a, b) => a.order - b.order).forEach(ts => {
        const option = document.createElement('option');
        option.value = ts.slot;
        option.textContent = selectedDay
            ? (ts.start_time && ts.end_time
                ? `${formatTime(ts.start_time)} – ${formatTime(ts.end_time)}`
                : ts.slot)
            : ts.label;
        option.setAttribute('data-day', ts.day);
        timeSlotFilter.appendChild(option);
    });

    timeSlotFilter.value = slots.some(ts => ts.slot === currentSlot) ? currentSlot : '';
}

function updateFilterIndicators() {
    const searchVal  = document.getElementById('search').value;
    const slotVal    = document.getElementById('timeSlotFilter').value;
    const trackVal   = document.getElementById('trackFilter').value;
    const typeVal    = document.getElementById('typeFilter').value;

    document.querySelector('label[for="search"]').classList.toggle('filter-active', !!searchVal);
    document.querySelector('label[for="timeSlotFilter"]').classList.toggle('filter-active', !!slotVal);
    document.querySelector('label[for="trackFilter"]').classList.toggle('filter-active', !!trackVal);
    document.querySelector('label[for="typeFilter"]').classList.toggle('filter-active', !!typeVal);
}

function resetAllFilters() {
    document.getElementById('search').value = '';
    document.getElementById('timeSlotFilter').value = '';
    document.getElementById('trackFilter').value = '';
    document.getElementById('typeFilter').value = '';

    document.getElementById('trackFilter')
        .closest('.track-select-wrapper')
        .style.setProperty('--track-color', '#e5e5e5');

    document.querySelectorAll('.day-tab').forEach(t => t.classList.remove('active'));
    document.querySelector('.day-tab[data-day=""]').classList.add('active');

    updateTimeSlotDropdown('');
    updateFilterIndicators();
    renderSchedule();
}

function buildBioMap() {
    bioMap = {};
    biosData.forEach(bio => {
        const addKey = name => { if (name) bioMap[name] = bio; };
        addKey(bio.name);
        if (bio.name.startsWith('Dr. ')) addKey(bio.name.slice(4));
        else addKey('Dr. ' + bio.name);
        if (bio.name.includes('-')) addKey(bio.name.replace(/-/g, ' '));
    });
}

function normalizeTitle(t) {
    return (t || '').toLowerCase().trim()
        .replace(/[‘’]/g, "'")
        .replace(/[“”]/g, '"');
}

function buildAwardMap() {
    awardMap = {};
    awardsData.forEach(row => {
        if (!row.paper_title) return;
        awardMap[normalizeTitle(row.paper_title)] = {
            award: row.award,
            rank:  row.rank
        };
    });
}

function getAwardForTitle(title) {
    if (!title) return null;
    const norm = normalizeTitle(title);
    if (awardMap[norm]) return awardMap[norm];
    // startsWith match (award title may be prefix of schedule title or vice versa)
    for (const [k, v] of Object.entries(awardMap)) {
        if (norm.startsWith(k) || k.startsWith(norm)) return v;
    }
    return null;
}

function canonicalPersonName(value) {
    return String(value || '')
        .split('(')[0]
        .trim()
        .normalize('NFD')
        .replace(/[\u0300-\u036f]/g, '')
        .replace(/[‘’]/g, "'")
        .replace(/^(?:the\s+rt\s+hon\s+|professor\s+sir\s+|professor\s+|prof\.?\s+|dr\.?\s+|sir\s+)+/i, '')
        .replace(/(?:\s+(?:cbe|ceng|fice|freng|frs))+$/i, '')
        .replace(/\s+/g, ' ')
        .toLowerCase();
}

function speakerKey(bio) {
    return String((bio && (bio.person_id || bio.image)) || '')
        .trim()
        .replace(/[^a-zA-Z0-9_-]/g, '-');
}

function findBioForName(panelistStr) {
    if (!panelistStr || panelistStr.trim() === 'TBD') return null;
    const target = canonicalPersonName(panelistStr);
    if (!target) return null;
    return biosData.find(bio => canonicalPersonName(bio && bio.name) === target) || null;
}

function renderPanelistLine(panelistStr) {
    const trimmed = String(panelistStr || '').trim();
    if (!trimmed) return '';
    const bio = findBioForName(trimmed);
    const key = speakerKey(bio);
    if (!bio || !key) return escapeHtml(trimmed);
    const parenIdx = trimmed.indexOf('(');
    const namePart = parenIdx >= 0 ? trimmed.slice(0, parenIdx).trim() : trimmed;
    const restPart = parenIdx >= 0 ? ' ' + trimmed.slice(parenIdx) : '';
    return `<a class="speaker-link" href="#" onclick="showSpeaker('${key}'); return false;">${escapeHtml(namePart)}</a>${escapeHtml(restPart)}`;
}

function switchView(view) {
    document.querySelectorAll('.view-btn').forEach(btn => {
        btn.classList.toggle('active', btn.getAttribute('data-view') === view);
    });
    document.getElementById('scheduleView').style.display  = view === 'schedule'  ? '' : 'none';
    document.getElementById('speakersView').style.display  = view === 'speakers'  ? '' : 'none';
    document.getElementById('awardsView').style.display    = view === 'awards'    ? '' : 'none';
    document.getElementById('mapView').style.display       = view === 'map'       ? '' : 'none';
    document.getElementById('sponsorsView').style.display  = view === 'sponsors' ? '' : 'none';
    document.getElementById('oxfordView').style.display    = view === 'oxford'   ? '' : 'none';
    document.getElementById('mobileFilterToggle').style.display = view === 'schedule' ? '' : 'none';
}

function showSpeaker(slug) {
    switchView('speakers');
    setTimeout(() => {
        const el = document.getElementById('speaker-' + slug);
        if (!el) return;
        el.scrollIntoView({ behavior: 'smooth', block: 'center' });
        el.classList.remove('speaker-highlight');
        void el.offsetWidth;
        el.classList.add('speaker-highlight');
    }, 50);
}

function renderSpeakers() {
    const sorted = [...biosData].sort((a, b) => {
        const lastName = name => canonicalPersonName(name).split(' ').pop() || '';
        return lastName(a && a.name).localeCompare(lastName(b && b.name));
    });

    const html = sorted.map(bio => {
        const key = speakerKey(bio);
        const image = String((bio && bio.image) || '').trim();
        const imgHtml = image
            ? `<img src="images/bios/${encodeURIComponent(image)}.png" class="speaker-photo" alt="${escapeHtml(bio.name)}" onerror="this.outerHTML='<div class=\'speaker-photo-placeholder\' aria-label=\'No speaker image available\'>&#128100;</div>'">`
            : `<div class="speaker-photo-placeholder" aria-label="No speaker image available">&#128100;</div>`;
        return `
        <div class="speaker-card" id="speaker-${key}">
            ${imgHtml}
            <div class="speaker-info">
                <div class="speaker-name">${escapeHtml(bio.name)}</div>
                <p class="speaker-bio">${escapeHtml(bio.bio || '')}</p>
            </div>
        </div>`;
    }).join('');

    document.getElementById('speakersGrid').innerHTML = html;
}

function renderAwards() {
    // Group entries by award (preserving award_order)
    const groups = [];
    const seen = {};
    awardsData.forEach(row => {
        if (!seen[row.award]) {
            seen[row.award] = { award: row.award, description: row.description, entries: [] };
            groups.push(seen[row.award]);
        }
        seen[row.award].entries.push(row);
    });

    const luncheonNote = `<div class="awards-luncheon-note">
        Join us Saturday, September 5, at the awards luncheon, when we will recognise all awardees.
    </div>`;

    const cardsHtml = groups.map(g => {
        const entriesHtml = g.entries.map(e => {
            const isWinner = e.rank === 'Winner';
            const badgeClass = isWinner ? 'rank-winner' : 'rank-runnerup';
            const badgeLabel = isWinner ? 'Winner' : 'Runner-up';

            const pubHtml = e.publication
                ? `<div class="award-publication">${escapeHtml(e.publication)}${e.doi ? ` — <a href="${escapeHtml(e.doi)}" target="_blank" rel="noopener">DOI</a>` : ''}</div>`
                : '';

            const committeeHtml = e.committee
                ? `<div class="award-committee"><strong>Dissertation Committee:</strong> ${escapeHtml(e.committee)}</div>`
                : '';

            return `
            <div class="award-entry">
                <span class="award-rank-badge ${badgeClass}">${badgeLabel}</span>
                <div class="award-entry-body">
                    <div class="award-paper-title">${escapeHtml(e.paper_title)}</div>
                    <div class="award-authors">${escapeHtml(e.authors)}</div>
                    ${pubHtml}${committeeHtml}
                </div>
            </div>`;
        }).join('');

        const awardsCommittee = g.entries[0].awards_committee;
        const awardsCommitteeHtml = awardsCommittee
            ? `<div class="award-committee" style="margin: 0 1.25rem 1rem; padding-top: 0.6rem; border-top: 1px solid #f0f0f0;"><strong>Award Committee:</strong> ${escapeHtml(awardsCommittee)}</div>`
            : '';

        return `
        <div class="award-card">
            <div class="award-header">
                <div class="award-name">${escapeHtml(g.award)}</div>
                <div class="award-description">${escapeHtml(g.description)}</div>
            </div>
            <div class="award-entries">${entriesHtml}</div>
            ${awardsCommitteeHtml}
        </div>`;
    }).join('');

    document.getElementById('awardsGrid').innerHTML = luncheonNote + cardsHtml;
}

function getCategoryClass(category) {
    if (!category) return '';
    if (category.includes('General Industry Studies'))                                       return 'cat-general';
    if (category.includes('Health Care') || category.includes('Pharmaceuticals'))           return 'cat-health';
    if (category.includes('Labor Markets') || category.includes('Future of Work'))          return 'cat-labor';
    if (category.includes('Operations') || category.includes('Supply Chain'))               return 'cat-operations';
    if (category.includes('Public Policy') || category.includes('Global Competitiveness'))  return 'cat-policy';
    if (category.includes('Sustainable Innovation') || category.includes('Energy'))         return 'cat-sustainability';
    if (category.includes('Innovation') || category.includes('Entrepreneurship'))           return 'cat-innovation';
    if (category === 'Cross-Track')                                                           return 'cat-cross-track';
    return '';
}

// Committee rendering
function renderCommittee() {
    const container = document.getElementById('committeeContainer');
    if (!container) return;

    const board = asArray(committeeData.board, 'committee_data.json board');
    const oxcc = asArray(committeeData.oxcc || committeeData.iscc || [], 'committee_data.json oxcc');
    const streamChairs = asArray(committeeData.stream_chairs || [], 'committee_data.json stream_chairs');

    // The committee is supplementary content. Missing committee groups should
    // never prevent the main schedule from loading.
    if (board.length === 0 && oxcc.length === 0 && streamChairs.length === 0) {
        container.innerHTML = '';
        return;
    }

    function makeTable(members, isStream) {
        const safeMembers = asArray(members, 'committee members');
        if (safeMembers.length === 0) return '<p style="color:#666;">No entries available.</p>';
        const rows = safeMembers.map(m => {
            const left = `<strong>${escapeHtml(m.name)}</strong>`;
            const right = isStream
                ? `<em>${escapeHtml(m.role)}</em>`
                : `<em>${escapeHtml(m.role)}, ${escapeHtml(m.affiliation)}</em>`;
            return `<tr>
                <td style="padding:0.35rem 1.2rem 0.35rem 0; white-space:nowrap; vertical-align:top;">${left}</td>
                <td style="padding:0.35rem 0; color:#555; vertical-align:top;">${right}</td>
            </tr>`;
        }).join('');
        return `<table style="border-collapse:collapse; text-align:left;">${rows}</table>`;
    }

    container.innerHTML = `
        <h2 style="margin-bottom:1.5rem;">Thank You to all the ISA Organizers!</h2>
        <h3 style="margin:0 0 0.6rem; font-size:1.05rem; text-decoration:underline;">Board of Directors</h3>
        ${makeTable(board, false)}
        <h3 style="margin:1.5rem 0 0.6rem; font-size:1.05rem; text-decoration:underline;">Oxford International Conference Committee</h3>
        ${makeTable(oxcc, false)}
        <h3 style="margin:1.5rem 0 0.6rem; font-size:1.05rem; text-decoration:underline;">Research Stream Chairs</h3>
        ${makeTable(streamChairs, true)}
    `;
}

// Lightbox
const lightboxOverlay = document.getElementById('lightbox-overlay');
const lightboxImg     = document.getElementById('lightbox-img');

// Calendar helpers
const CONFERENCE_TIME_ZONE = 'Europe/London';
const CONFERENCE_LOCATION = 'Saïd Business School, Oxford University, UK';

function toggleCalMenu(btn, key) {
    const menu = btn.nextElementSibling;
    const isOpen = menu.style.display !== 'none';
    document.querySelectorAll('.cal-menu').forEach(m => m.style.display = 'none');
    if (!isOpen) menu.style.display = 'block';
}

function calFormatLocal(dateStr, timeStr) {
    const date = String(dateStr || '').replace(/-/g, '');
    const parts = String(timeStr || '').split(':');
    const hour = String(parts[0] || '00').padStart(2, '0');
    const minute = String(parts[1] || '00').padStart(2, '0');
    const second = String(parts[2] || '00').padStart(2, '0');
    return `${date}T${hour}${minute}${second}`;
}

function calZonedDateToUTC(dateStr, timeStr, timeZone = CONFERENCE_TIME_ZONE) {
    const [year, month, day] = String(dateStr).split('-').map(Number);
    const [hour = 0, minute = 0, second = 0] = String(timeStr).split(':').map(Number);
    const desiredAsUTC = Date.UTC(year, month - 1, day, hour, minute, second);
    let instant = desiredAsUTC;

    const formatter = new Intl.DateTimeFormat('en-GB', {
        timeZone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
        hourCycle: 'h23'
    });

    // Resolve the UTC instant whose wall-clock value in Europe/London matches
    // the date and time supplied by the conference schedule.
    for (let i = 0; i < 3; i += 1) {
        const values = {};
        formatter.formatToParts(new Date(instant)).forEach(part => {
            if (part.type !== 'literal') values[part.type] = Number(part.value);
        });
        const formattedAsUTC = Date.UTC(
            values.year,
            values.month - 1,
            values.day,
            values.hour,
            values.minute,
            values.second
        );
        const adjustment = desiredAsUTC - formattedAsUTC;
        instant += adjustment;
        if (adjustment === 0) break;
    }

    return new Date(instant);
}

function calFormatUTC(date) {
    const pad = n => String(n).padStart(2, '0');
    return `${date.getUTCFullYear()}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}` +
        `T${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`;
}

function calFormatDTUTC(dateStr, timeStr) {
    return calFormatUTC(calZonedDateToUTC(dateStr, timeStr));
}

function calEscapeICS(value) {
    return String(value || '')
        .replace(/\\/g, '\\\\')
        .replace(/;/g, '\\;')
        .replace(/,/g, '\\,')
        .replace(/\r?\n/g, '\\n');
}

function buildCalDescription(s) {
    const lines = [];
    if (s.session_chair) lines.push('Session Chair: ' + s.session_chair);
    if (s.papers && s.papers.length > 0 && s.type !== 'event') {
        const first = s.papers[0];
        const panelFormat = ['panel', 'special_session', 'plenary'].includes(s.type);
        if (panelFormat) {
            if (first.moderator) lines.push('Moderator: ' + first.moderator);
            if (first.authors) {
                const label = s.type === 'plenary' ? 'Speakers' : 'Panelists';
                const people = first.authors
                    .split(/[;\n]+/)
                    .map(value => value.trim())
                    .filter(Boolean)
                    .map(value => '- ' + value)
                    .join('\n');
                if (people) lines.push('\n' + label + ':\n' + people);
            }
        } else {
            const paperList = s.papers
                .filter(p => p.title)
                .map(p => '- ' + p.title + (p.authors ? ' (' + p.authors.replace(/\*/g, '') + ')' : ''))
                .join('\n');
            if (paperList) lines.push('\nPapers:\n' + paperList);
        }
    }
    return lines.join('\n');
}

function calLocation(s) {
    return (s.room ? s.room + ', ' : '') + CONFERENCE_LOCATION;
}

function calToGoogle(key) {
    const s = sessionCalendarData[key];
    if (!s || !s.date || !s.start_time || !s.end_time) return;

    const start = calFormatDTUTC(s.date, s.start_time);
    const end = calFormatDTUTC(s.date, s.end_time);
    const url = new URL('https://calendar.google.com/calendar/render');
    url.searchParams.set('action', 'TEMPLATE');
    url.searchParams.set('text', s.session_name);
    url.searchParams.set('dates', start + '/' + end);
    url.searchParams.set('ctz', CONFERENCE_TIME_ZONE);
    url.searchParams.set('location', calLocation(s));
    const desc = buildCalDescription(s);
    if (desc) url.searchParams.set('details', desc);
    window.open(url.toString(), '_blank', 'noopener');
    document.querySelectorAll('.cal-menu').forEach(m => m.style.display = 'none');
}

function calDownloadICS(key) {
    const s = sessionCalendarData[key];
    if (!s || !s.date || !s.start_time || !s.end_time) return;

    const startLocal = calFormatLocal(s.date, s.start_time);
    const endLocal = calFormatLocal(s.date, s.end_time);
    const stamp = calFormatUTC(new Date());
    const uidPart = String(s.session_id || key || 'session').replace(/[^a-zA-Z0-9._-]/g, '-');
    const uid = `isa-oxford-2026-${uidPart}-${startLocal}@isa2026.org`;
    const rawDesc = buildCalDescription(s);

    const lines = [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//ISA Oxford 2026//Conference Schedule//EN',
        'CALSCALE:GREGORIAN',
        'METHOD:PUBLISH',
        'X-WR-CALNAME:ISA Oxford 2026',
        'X-WR-TIMEZONE:' + CONFERENCE_TIME_ZONE,
        'BEGIN:VTIMEZONE',
        'TZID:' + CONFERENCE_TIME_ZONE,
        'X-LIC-LOCATION:' + CONFERENCE_TIME_ZONE,
        'BEGIN:DAYLIGHT',
        'TZOFFSETFROM:+0000',
        'TZOFFSETTO:+0100',
        'TZNAME:BST',
        'DTSTART:19700329T010000',
        'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU',
        'END:DAYLIGHT',
        'BEGIN:STANDARD',
        'TZOFFSETFROM:+0100',
        'TZOFFSETTO:+0000',
        'TZNAME:GMT',
        'DTSTART:19701025T020000',
        'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU',
        'END:STANDARD',
        'END:VTIMEZONE',
        'BEGIN:VEVENT',
        'UID:' + uid,
        'DTSTAMP:' + stamp,
        'DTSTART;TZID=' + CONFERENCE_TIME_ZONE + ':' + startLocal,
        'DTEND;TZID=' + CONFERENCE_TIME_ZONE + ':' + endLocal,
        'SUMMARY:' + calEscapeICS(s.session_name),
        'LOCATION:' + calEscapeICS(calLocation(s))
    ];
    if (rawDesc) lines.push('DESCRIPTION:' + calEscapeICS(rawDesc));
    lines.push('END:VEVENT', 'END:VCALENDAR');

    const blob = new Blob([lines.join('\r\n')], { type: 'text/calendar;charset=utf-8' });
    const a = document.createElement('a');
    const objectUrl = URL.createObjectURL(blob);
    a.href = objectUrl;
    a.download = String(s.session_name || 'ISA_Oxford_2026')
        .replace(/[^a-zA-Z0-9 ]/g, '')
        .replace(/\s+/g, '_')
        .substring(0, 50) + '.ics';
    a.click();
    setTimeout(() => URL.revokeObjectURL(objectUrl), 0);
    document.querySelectorAll('.cal-menu').forEach(m => m.style.display = 'none');
}

document.addEventListener('click', e => {
    if (!e.target.closest('.cal-wrapper')) {
        document.querySelectorAll('.cal-menu').forEach(m => m.style.display = 'none');
    }
    if (e.target.hasAttribute('data-lightbox')) {
        lightboxImg.src = e.target.src;
        lightboxImg.alt = e.target.alt;
        lightboxOverlay.classList.add('active');
    }
});

lightboxOverlay.addEventListener('click', () => {
    lightboxOverlay.classList.remove('active');
    lightboxImg.src = '';
});

document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
        lightboxOverlay.classList.remove('active');
        lightboxImg.src = '';
    }
});
