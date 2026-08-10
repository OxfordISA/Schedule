from docx import Document
from pathlib import Path
import pandas as pd, csv, re, json, zipfile, shutil, math
from datetime import datetime, timezone

BASE=Path('/mnt/data')
DOC=BASE/'Programme Book v7 Linked.docx'
OUT=BASE/'updated_csvs_from_programme_book_v7'
if OUT.exists(): shutil.rmtree(OUT)
OUT.mkdir()

# ---------- helpers ----------
def clean(s):
    if s is None: return ''
    s=str(s).replace('\xa0',' ').replace('\u200b','')
    s=s.replace('—','-').replace('–','-')
    s=re.sub(r'\s+', ' ', s).strip()
    return s

def norm(s):
    s=clean(s).lower()
    s=s.replace('’',"'").replace('‘',"'").replace('“','"').replace('”','"')
    s=re.sub(r'[^a-z0-9]+',' ',s)
    return re.sub(r'\s+',' ',s).strip()

def slug(name):
    x=norm(name)
    return x.replace(' ','-')

def title_case_room(room):
    return clean(room)

def time_to_hms(t):
    t=clean(t).upper().replace('.',':').replace(' ', '')
    m=re.match(r'^(\d{1,2})(?::(\d{2}))?(AM|PM)?$', t)
    if not m: return ''
    h=int(m.group(1)); mi=int(m.group(2) or 0); ap=m.group(3)
    if ap == 'PM' and h != 12: h += 12
    if ap == 'AM' and h == 12: h = 0
    return f'{h:02d}:{mi:02d}:00'

def fmt_ampm_from_hms(hms):
    if not hms: return ''
    h,m,_=map(int,hms.split(':'))
    ap='PM' if h>=12 else 'AM'
    h12=h%12 or 12
    return f'{h12}:{m:02d} {ap}'

def split_timerange(s):
    s=clean(s).replace(' - ','-')
    m=re.search(r'(\d{1,2}(?::\d{2}|\.\d{2})?\s*(?:am|pm|AM|PM)?)\s*-\s*(\d{1,2}(?::\d{2}|\.\d{2})?\s*(?:am|pm|AM|PM)?)', s)
    if not m: return ('','')
    a,b=m.group(1),m.group(2)
    # propagate am/pm if needed
    if not re.search(r'(AM|PM|am|pm)', a) and re.search(r'(AM|PM|am|pm)', b):
        a += re.search(r'(AM|PM|am|pm)', b).group(1)
    return time_to_hms(a), time_to_hms(b)

def date_for_day(day):
    d=clean(day)
    if 'Thursday' in d or '3 September' in d or '3 Sept' in d: return '2026-09-03','Thursday'
    if 'Friday' in d or '4 September' in d or '4 Sept' in d: return '2026-09-04','Friday'
    if 'Saturday' in d or '5 September' in d or '5 Sept' in d: return '2026-09-05','Saturday'
    return '', ''

def epoch_order(date,start):
    if not date or not start: return ''
    dt=datetime.fromisoformat(date+'T'+start).replace(tzinfo=timezone.utc)
    return float(dt.timestamp())

track_names={
 'GIS':'General Industry Studies',
 'HC':'Health Care Systems, Biotechnology, and Pharmaceuticals',
 'I&E':'Innovation, Entrepreneurship, and AI-Driven Transformation',
 'LAB':'Labor Markets, Organizations, and the Future of Work',
 'OSCM':'Operations, Supply Chain, and AI-Enhanced Industry 4.0',
 'PP':'Public Policy and Global Competitiveness',
 'SUS':'Sustainable Innovation, Energy, and Mobility',
 'XTrack':'Cross-Track'
}
def category_from_session_id(code):
    for k in sorted(track_names, key=len, reverse=True):
        if code.startswith(k): return track_names[k]
    return ''

# ---------- load docx ----------
doc=Document(DOC)
paras=[]
for p in doc.paragraphs:
    txt=clean(p.text)
    if txt: paras.append((txt,p.style.name))

# ---------- extract paper/detail sessions from docx ----------
session_re=re.compile(r'^(GIS|I&E|LAB|OSCM|SUS|HC|PP|XTrack)\d+\s*\|\s*(.*)$')
chunks=[]; current_slot=''; current_day=''; cur=None
for txt,st in paras:
    if st=='Heading 1' and re.search(r'(Thursday|Friday|Saturday)',txt) and re.search(r'\d',txt):
        if cur: chunks.append(cur); cur=None
        current_slot=txt
        continue
    if st=='Heading 2':
        if cur: chunks.append(cur)
        cur={'heading':txt,'slot_text':current_slot,'lines':[]}
    elif cur:
        cur['lines'].append(txt)
if cur: chunks.append(cur)

# room abbreviations from detailed headings
room_map={'Rhodes Trust':'Rhodes Trust','Rhodes':'Rhodes Trust','Edmund Safra':'Edmund Safra','LT4':'LT4','Lecture Theatre 4':'LT4','LT5':'LT5','Lecture Theatre 5':'LT5','SR A':'SR A','Seminar Room A':'SR A','SR13':'SR13','Seminar Room 13':'SR13','Founders Room':'Founders Room','NMLT':'NMLT'}

paper_sessions=[]; extracted_papers=[]; discussion_panel_people=[]
for ch in chunks:
    heading=clean(ch['heading'])
    mhead=re.match(r'(.+?)\s*\[([^\]]+)\]\s*$', heading)
    sname=mhead.group(1).strip() if mhead else heading
    room=mhead.group(2).strip() if mhead else ''
    room=room_map.get(room,room)
    st,et=split_timerange(ch['slot_text'])
    date,day=date_for_day(ch['slot_text'])
    code=''; session_type='Regular paper session'; chair=''; moderator=''
    for ln in ch['lines'][:4]:
        mm=session_re.match(ln)
        if mm:
            code=ln.split('|')[0].strip()
            if 'Discussion Panel' in ln: session_type='Discussion Panel'
            if 'Organised Paper Session' in ln or 'Organized Paper Session' in ln: session_type='Organised Paper Session'
            em=re.search(r'(Session chair|Session Chair|Moderator)\s*:\s*(.+)$', ln)
            if em:
                if em.group(1).lower().startswith('moderator'): moderator=em.group(2).strip()
                else: chair=em.group(2).strip()
    if not code: continue
    for ln in ch['lines']:
        if ln.lower().startswith(('session chair:', 'session chair :')):
            chair=re.sub(r'^Session Chair\s*:\s*|^Session chair\s*:\s*','',ln,flags=re.I).strip()
        if ln.lower().startswith('moderator:'):
            moderator=re.sub(r'^Moderator\s*:\s*','',ln,flags=re.I).strip()
        if ln.startswith('- '):
            party=ln[2:].strip()
            discussion_panel_people.append({'session_id':code,'session_name':sname,'person':party})
    paper_sessions.append({'session_id':code,'session_name':sname,'session_type':session_type,'session_chair':chair or moderator,'source':'Programme Book v7 Linked.docx','room':room,'date':date,'day':day,'start_time':st,'end_time':et})
    if session_type=='Discussion Panel':
        continue
    useful=[]
    for ln in ch['lines']:
        if session_re.match(ln): continue
        if ln.lower().startswith(('session chair','moderator','panelists')): continue
        if ln.startswith('- '): continue
        useful.append(ln)
    i=0; order=1
    while i+2 < len(useful):
        title,authors,affils=useful[i],useful[i+1],useful[i+2]
        if re.match(r'^\d', title) or len(title)<8:
            i+=1; continue
        extracted_papers.append({'session_id':code,'session_name':sname,'paper_order':order,'title':title,'authors_doc':authors,'affiliations_doc':affils,'room':room,'date':date,'day':day,'start_time':st,'end_time':et})
        order+=1; i+=3

# ---------- special sessions/plenaries from fixed master sections ----------
# Front overview and detailed pages conflict for Saturday rooms. Use front programme overview as attendee-facing schedule.
specials = [
    {'id':'PL1','date':'2026-09-03','day':'Thursday','start_time':'15:45:00','end_time':'16:45:00','room':'NMLT','title':'Opening Plenary: The Geopolitics of Industrial Policy','category':'Plenary','moderator':'Dr Monica Gorman','panelists':'The Rt Hon Lord Hague of Richmond','description':''},
    {'id':'PL2','date':'2026-09-04','day':'Friday','start_time':'10:25:00','end_time':'11:25:00','room':'NMLT','title':'Plenary: Value Chains and Industrial Innovation Policy','category':'Plenary','moderator':'Professor Sir Mike Gregory','panelists':'Julia Sutcliffe; Eoin O’Sullivan','description':'Insert abstract here'},
    {'id':'SS1','date':'2026-09-03','day':'Thursday','start_time':'13:00:00','end_time':'14:00:00','room':'Rhodes Trust','title':'Drones','category':'Special Session','moderator':'Mike Lewis','panelists':'Drone 1; Drone 2','description':'Insert abstract here'},
    {'id':'SS2','date':'2026-09-03','day':'Thursday','start_time':'13:00:00','end_time':'14:00:00','room':'LT4','title':'Public Policy and the Digital Stack','category':'Special Session','moderator':'Angela Garcia Calvo','panelists':'Diane Coyle; Annabelle Gawer; Helena Malikova','description':''},
    {'id':'SS3','date':'2026-09-04','day':'Friday','start_time':'11:30:00','end_time':'12:30:00','room':'Rhodes Trust','title':'Space: Can the Final Frontier Become a Market?','category':'Special Session','moderator':'Mehdi Montakhabi','panelists':'Dr Paul Bate; Rob Desborough; Nigel Chandler; Raja Roy','description':''},
    {'id':'SS4','date':'2026-09-04','day':'Friday','start_time':'11:30:00','end_time':'12:30:00','room':'LT4','title':'Drug Shortages: Drivers, Consequences, and Solutions','category':'Special Session','moderator':'John Gray','panelists':'Dr. Markus Felgenhauer; Damien Holly; Mujaheed Shaikh','description':''},
    {'id':'SS5','date':'2026-09-04','day':'Friday','start_time':'15:10:00','end_time':'16:10:00','room':'Rhodes Trust','title':'Semiconductors','category':'Special Session','moderator':'Travis Mosier','panelists':'Katie Hore; YYY; Sebastian Weiske','description':'Insert text here'},
    {'id':'SS6','date':'2026-09-04','day':'Friday','start_time':'15:10:00','end_time':'16:10:00','room':'LT4','title':'Infrastructure—From Concrete to Cloud: A Laggard Leviathan or a Leading Light?','category':'Special Session','moderator':'Daniel Erian Armanios','panelists':'Alison Baptiste; Jim Hall; Julia Pyke; Chetan Kotur','description':''},
    {'id':'SS7','date':'2026-09-05','day':'Saturday','start_time':'10:30:00','end_time':'11:30:00','room':'Rhodes Trust','title':'What Is Industry Studies Research?','category':'Special Session','moderator':'John Gray','panelists':'Saurabh Bansal; Laura Dupin; Juliane Reinecke','description':''},
    {'id':'SS8','date':'2026-09-05','day':'Saturday','start_time':'10:30:00','end_time':'11:30:00','room':'LT4','title':'Resilience and Reconfiguration of Global Supply Chains','category':'Special Session','moderator':'Jagjit Singh Srai','panelists':'Edward Anderson; Nitin Joglekar','description':''},
]
# Get abstracts from exact paragraph titles where available
pt=[x[0] for x in paras]
for sp in specials:
    matches=[i for i,t in enumerate(pt) if t==sp['title'] or t.startswith(sp['title']+' ' ) or t.startswith(sp['title']+'\n')]
    # special title sometimes starts with only base title
    if not matches:
        base=sp['title'].split(':')[0]
        matches=[i for i,t in enumerate(pt) if t.startswith(base)]
    if matches:
        idx=matches[0]
        # Abstract is commonly two paragraphs after title if separate time paragraph, or one after if merged
        candidates=[]
        if idx+2 < len(pt): candidates.append(pt[idx+2])
        if idx+1 < len(pt): candidates.append(pt[idx+1])
        for c in candidates:
            if not re.search(r'(Thursday|Friday|Saturday).*(\d|am|pm|AM|PM)', c) and c not in ['Insert abstract here','Insert text here'] and len(c)>20:
                sp['description']=c
                break
# Correct opening plenary abstract if prefixed [Draft]
for sp in specials:
    sp['description']=clean(sp['description'])

# ---------- map paper titles to existing submissions ----------
subs=pd.read_csv(BASE/'submissions.csv', dtype=str, keep_default_na=False)
subs['_norm_title']=subs['title'].map(norm)
title_to_sub={}
for _,r in subs.iterrows():
    title_to_sub[r['_norm_title']]=r.to_dict()
# fuzzy fallback by startswith
sub_norms=list(title_to_sub.keys())
def match_submission(title):
    nt=norm(title)
    if nt in title_to_sub: return title_to_sub[nt]
    for k in sub_norms:
        if nt.startswith(k) or k.startswith(nt): return title_to_sub[k]
    return None

# Preserve previous chair choices where the docx has blank chair (e.g. I&E1)
old_chairs=pd.read_csv(BASE/'session-chairs.csv', dtype=str, keep_default_na=False)
old_chair_map=dict(zip(old_chairs['session_id'], old_chairs['session_chair']))
for s in paper_sessions:
    if not s['session_chair'] and old_chair_map.get(s['session_id']):
        s['session_chair']=old_chair_map[s['session_id']]

# ---------- slot definitions ----------
slot_rows=[
('Offsite','TH01','2026-09-03','Thursday','08:00:00','12:00:00'),('Oxford walking tour','TH02','2026-09-03','Thursday','10:00:00','12:00:00'),('SBS Foyer','TH03','2026-09-03','Thursday','12:00:00','13:00:00'),('Rhodes Trust','TH04','2026-09-03','Thursday','13:00:00','14:00:00'),('LT4','TH04','2026-09-03','Thursday','13:00:00','14:00:00'),
('Rhodes Trust','TH05','2026-09-03','Thursday','14:05:00','15:15:00'),('Edmund Safra','TH05','2026-09-03','Thursday','14:05:00','15:15:00'),('LT4','TH05','2026-09-03','Thursday','14:05:00','15:15:00'),('LT5','TH05','2026-09-03','Thursday','14:05:00','15:15:00'),('SR A','TH05','2026-09-03','Thursday','14:05:00','15:15:00'),('Founders Room','TH05','2026-09-03','Thursday','14:05:00','15:15:00'),
('SBS Foyer','TH06','2026-09-03','Thursday','15:15:00','15:45:00'),('NMLT','TH07','2026-09-03','Thursday','15:45:00','16:45:00'),('Rhodes Trust','TH08','2026-09-03','Thursday','16:50:00','18:00:00'),('Edmund Safra','TH08','2026-09-03','Thursday','16:50:00','18:00:00'),('LT4','TH08','2026-09-03','Thursday','16:50:00','18:00:00'),('LT5','TH08','2026-09-03','Thursday','16:50:00','18:00:00'),('SR A','TH08','2026-09-03','Thursday','16:50:00','18:00:00'),('SR13','TH08','2026-09-03','Thursday','16:50:00','18:00:00'),('Founders Room','TH08','2026-09-03','Thursday','16:50:00','18:00:00'),('Rhodes House','TH09','2026-09-03','Thursday','18:30:00','20:30:00'),
('SBS Foyer','FR01','2026-09-04','Friday','08:15:00','08:45:00'),('Rhodes Trust','FR02','2026-09-04','Friday','08:45:00','09:55:00'),('Edmund Safra','FR02','2026-09-04','Friday','08:45:00','09:55:00'),('LT4','FR02','2026-09-04','Friday','08:45:00','09:55:00'),('LT5','FR02','2026-09-04','Friday','08:45:00','09:55:00'),('SR A','FR02','2026-09-04','Friday','08:45:00','09:55:00'),('Founders Room','FR02','2026-09-04','Friday','08:45:00','09:55:00'),
('SBS Foyer','FR03','2026-09-04','Friday','09:55:00','10:25:00'),('NMLT','FR04','2026-09-04','Friday','10:25:00','11:25:00'),('Rhodes Trust','FR05','2026-09-04','Friday','11:30:00','12:30:00'),('LT4','FR05','2026-09-04','Friday','11:30:00','12:30:00'),('SBS Foyer','FR06','2026-09-04','Friday','12:30:00','13:30:00'),
('Rhodes Trust','FR07','2026-09-04','Friday','13:30:00','14:40:00'),('Edmund Safra','FR07','2026-09-04','Friday','13:30:00','14:40:00'),('LT4','FR07','2026-09-04','Friday','13:30:00','14:40:00'),('LT5','FR07','2026-09-04','Friday','13:30:00','14:40:00'),('SR A','FR07','2026-09-04','Friday','13:30:00','14:40:00'),('SR13','FR07','2026-09-04','Friday','13:30:00','14:40:00'),('Founders Room','FR07','2026-09-04','Friday','13:30:00','14:40:00'),
('SBS Foyer','FR08','2026-09-04','Friday','14:40:00','15:10:00'),('Rhodes Trust','FR09','2026-09-04','Friday','15:10:00','16:10:00'),('LT4','FR09','2026-09-04','Friday','15:10:00','16:10:00'),
('Rhodes Trust','FR10','2026-09-04','Friday','16:20:00','17:30:00'),('Edmund Safra','FR10','2026-09-04','Friday','16:20:00','17:30:00'),('LT4','FR10','2026-09-04','Friday','16:20:00','17:30:00'),('LT5','FR10','2026-09-04','Friday','16:20:00','17:30:00'),('SR A','FR10','2026-09-04','Friday','16:20:00','17:30:00'),('Founders Room','FR10','2026-09-04','Friday','16:20:00','17:30:00'),('NMLT','FR10','2026-09-04','Friday','16:20:00','17:30:00'),('Free time','FR11','2026-09-04','Friday','17:30:00','18:45:00'),('Balliol College','FR12','2026-09-04','Friday','18:45:00','22:00:00'),
('SBS Foyer','SA01','2026-09-05','Saturday','08:30:00','09:00:00'),('Rhodes Trust','SA02','2026-09-05','Saturday','09:00:00','10:10:00'),('Edmund Safra','SA02','2026-09-05','Saturday','09:00:00','10:10:00'),('LT4','SA02','2026-09-05','Saturday','09:00:00','10:10:00'),('LT5','SA02','2026-09-05','Saturday','09:00:00','10:10:00'),('SR A','SA02','2026-09-05','Saturday','09:00:00','10:10:00'),('SR13','SA02','2026-09-05','Saturday','09:00:00','10:10:00'),('SBS Foyer','SA03','2026-09-05','Saturday','10:10:00','10:30:00'),('Rhodes Trust','SA04','2026-09-05','Saturday','10:30:00','11:30:00'),('LT4','SA04','2026-09-05','Saturday','10:30:00','11:30:00'),
('Rhodes Trust','SA05','2026-09-05','Saturday','11:35:00','12:45:00'),('Edmund Safra','SA05','2026-09-05','Saturday','11:35:00','12:45:00'),('LT4','SA05','2026-09-05','Saturday','11:35:00','12:45:00'),('LT5','SA05','2026-09-05','Saturday','11:35:00','12:45:00'),('SR A','SA05','2026-09-05','Saturday','11:35:00','12:45:00'),('Founders Room','SA05','2026-09-05','Saturday','11:35:00','12:45:00'),('SBS Foyer','SA06','2026-09-05','Saturday','12:45:00','14:00:00')]
slot_df=pd.DataFrame(slot_rows, columns=['room','time_slot','date','day','start_time','end_time'])

def slot_for(date,start,room):
    r=slot_df[(slot_df.date==date)&(slot_df.start_time==start)&(slot_df.room==room)]
    if len(r): return r.iloc[0].time_slot
    r=slot_df[(slot_df.date==date)&(slot_df.start_time==start)]
    return r.iloc[0].time_slot if len(r) else ''

# ---------- schedule.csv and session-ids.csv ----------
# event rows
schedule_rows=[]
events=[
('EV1','Company visits','activity','2026-09-03','Thursday','08:00:00','12:00:00','','Offsite - Various'),
('EV2','Oxford Walking Tour','activity','2026-09-03','Thursday','10:00:00','12:00:00','','Oxford City Centre - Walking tour route'),
('EV3','Lunch','event','2026-09-03','Thursday','12:00:00','13:00:00','','Saïd Business School - SBS Foyer'),
('EV4','Coffee Break','event','2026-09-03','Thursday','15:15:00','15:45:00','','Saïd Business School - SBS Foyer'),
('EV5','Welcome Reception','event','2026-09-03','Thursday','18:30:00','20:30:00','','Rhodes House'),
('EV6','Breakfast','event','2026-09-04','Friday','08:15:00','08:45:00','','Saïd Business School - SBS Foyer'),
('EV7','Coffee Break','event','2026-09-04','Friday','09:55:00','10:25:00','','Saïd Business School - SBS Foyer'),
('EV8','Lunch','event','2026-09-04','Friday','12:30:00','13:30:00','','Saïd Business School - SBS Foyer'),
('EV9','Coffee Break','event','2026-09-04','Friday','14:40:00','15:10:00','','Saïd Business School - SBS Foyer'),
('EV10','Free time','event','2026-09-04','Friday','17:30:00','18:45:00','','Saïd Business School'),
('EV11','Gala Dinner','event','2026-09-04','Friday','18:45:00','22:00:00','','Balliol College'),
('EV12','Breakfast','event','2026-09-05','Saturday','08:30:00','09:00:00','','Saïd Business School - SBS Foyer'),
('EV13','Coffee Break','event','2026-09-05','Saturday','10:10:00','10:30:00','','Saïd Business School - SBS Foyer'),
('EV14','Lunch and Award Presentations','event','2026-09-05','Saturday','12:45:00','14:00:00','','Saïd Business School - SBS Foyer'),]
for eid,name,typ,date,day,st,et,slot,room in events:
    if not slot: slot=slot_for(date,st, room.split(' - ')[-1] if ' - ' in room else room)
    schedule_rows.append({'id':eid,'session_id':eid,'session_name':name,'paper_order':1,'time_slot':slot,'room':room,'date':date,'day':day,'start_time':st,'end_time':et,'time_order':epoch_order(date,st)})
# add specials
for sp in specials:
    slot=slot_for(sp['date'],sp['start_time'],sp['room'])
    sid=sp['id']
    schedule_rows.append({'id':sid,'session_id':sid,'session_name':sp['title'],'paper_order':1,'time_slot':slot,'room':sp['room'],'date':sp['date'],'day':sp['day'],'start_time':sp['start_time'],'end_time':sp['end_time'],'time_order':epoch_order(sp['date'],sp['start_time'])})
# add paper rows
new_session_ids=[]
unmatched=[]
chair_by_code={s['session_id']:s['session_chair'] for s in paper_sessions}
for p in extracted_papers:
    sub=match_submission(p['title'])
    if sub:
        pid=sub.get('id','')
        sess_name=p['session_name']
    else:
        pid='UNMATCHED_'+p['session_id']+'_'+str(p['paper_order'])
        unmatched.append(p['title'])
    slot=slot_for(p['date'],p['start_time'],p['room'])
    schedule_rows.append({'id':pid,'session_id':p['session_id'],'session_name':p['session_name'],'paper_order':p['paper_order'],'time_slot':slot,'room':p['room'],'date':p['date'],'day':p['day'],'start_time':p['start_time'],'end_time':p['end_time'],'time_order':epoch_order(p['date'],p['start_time'])})
    new_session_ids.append({'id':pid,'session_id':p['session_id'],'session_name':p['session_name'],'paper_order':p['paper_order']})
# add discussion panels from master as session-id rows if matching in submissions, e.g. LAB3 XTrack2 OSCM5 XTrack4
for s in paper_sessions:
    if s['session_type']!='Discussion Panel': continue
    sub=match_submission(s['session_name'])
    pid=sub['id'] if sub else {'LAB3':'114','XTrack2':'115','OSCM5':'212','XTrack4':'202'}.get(s['session_id'], s['session_id'])
    slot=slot_for(s['date'],s['start_time'],s['room'])
    new_session_ids.append({'id':pid,'session_id':s['session_id'],'session_name':s['session_name'],'paper_order':1})
    schedule_rows.append({'id':pid,'session_id':s['session_id'],'session_name':s['session_name'],'paper_order':1,'time_slot':slot,'room':s['room'],'date':s['date'],'day':s['day'],'start_time':s['start_time'],'end_time':s['end_time'],'time_order':epoch_order(s['date'],s['start_time'])})

# CSV schedule rows sorted
schedule_df=pd.DataFrame(schedule_rows)
schedule_df=schedule_df.sort_values(['date','start_time','session_id','paper_order'], kind='stable')
# session ids sorted similarly
sid_df=pd.DataFrame(new_session_ids).drop_duplicates(['id','session_id','paper_order'])

# ---------- session chairs ----------
schairs=[]
for s in sorted(paper_sessions, key=lambda x:(x['date'],x['start_time'],x['session_id'])):
    schairs.append({'session_id':s['session_id'],'session_name':s['session_name'],'session_type':s['session_type'],'session_chair':s['session_chair'],'source':'Programme Book v7 Linked.docx'})
# ---------- panels.csv ----------
panel_df=pd.DataFrame([{
    'id':sp['id'],'date': {'2026-09-03':'9/3/26','2026-09-04':'9/4/26','2026-09-05':'9/5/26'}[sp['date']],
    'time_start':fmt_ampm_from_hms(sp['start_time']),'time_end':fmt_ampm_from_hms(sp['end_time']),'room':sp['room'],'title':sp['title'],'category':sp['category'],'contact_author':'','contact_email':'','moderator':sp['moderator'],'panelists':sp['panelists'],'description':sp['description']
} for sp in specials])

# ---------- overview.csv ----------
overview_rows=[
['Thursday','8:00 AM','12:00 PM','4:00','Company visits','Offsite','Various','','','', ''],
['Thursday','10:00 AM','12:00 PM','2:00','Oxford Walking Tour','Oxford City Centre','Walking tour route','','','', ''],
['Thursday','12:00 PM','1:00 PM','1:00','Lunch','Saïd Business School','SBS Foyer','','','', ''],
['Thursday','1:00 PM','2:00 PM','1:00','Special sessions','Rhodes Trust; Saïd Business School','Rhodes Trust; LT4','','','', ''],
['Thursday','2:05 PM','3:15 PM','1:10','Concurrent paper and panel sessions','Saïd Business School','Various','','','', ''],
['Thursday','3:15 PM','3:45 PM','0:30','Coffee Break','Saïd Business School','SBS Foyer','','','', ''],
['Thursday','3:45 PM','4:45 PM','1:00','Plenary','Saïd Business School','NMLT','','','', ''],
['Thursday','4:50 PM','6:00 PM','1:10','Concurrent paper and panel sessions','Saïd Business School','Various','','','', ''],
['Thursday','6:30 PM','8:30 PM','2:00','Welcome Reception','Rhodes House','Rhodes House','','','', ''],
['Friday','8:15 AM','8:45 AM','0:30','Breakfast','Saïd Business School','SBS Foyer','','','', ''],
['Friday','8:45 AM','9:55 AM','1:10','Concurrent paper and panel sessions','Saïd Business School','Various','','','', ''],
['Friday','9:55 AM','10:25 AM','0:30','Coffee Break','Saïd Business School','SBS Foyer','','','', ''],
['Friday','10:25 AM','11:25 AM','1:00','Plenary','Saïd Business School','NMLT','','','', ''],
['Friday','11:30 AM','12:30 PM','1:00','Special sessions','Saïd Business School','Rhodes Trust; LT4','','','', ''],
['Friday','12:30 PM','1:30 PM','1:00','Lunch','Saïd Business School','SBS Foyer','','','', ''],
['Friday','1:30 PM','2:40 PM','1:10','Concurrent paper and panel sessions','Saïd Business School','Various','','','', ''],
['Friday','2:40 PM','3:10 PM','0:30','Coffee Break','Saïd Business School','SBS Foyer','','','', ''],
['Friday','3:10 PM','4:10 PM','1:00','Special sessions','Rhodes Trust; Saïd Business School','Rhodes Trust; LT4','','','', ''],
['Friday','4:20 PM','5:30 PM','1:10','Concurrent paper and panel sessions','Saïd Business School','Various','','','', ''],
['Friday','5:30 PM','6:45 PM','1:15','Free time','Saïd Business School','','','','', ''],
['Friday','6:45 PM','10:00 PM','3:15','Gala Dinner','Balliol College','Balliol College','','','', ''],
['Saturday','8:30 AM','9:00 AM','0:30','Breakfast','Saïd Business School','SBS Foyer','','','', ''],
['Saturday','9:00 AM','10:10 AM','1:10','Concurrent paper and panel sessions','Saïd Business School','Various','','','', ''],
['Saturday','10:10 AM','10:30 AM','0:20','Coffee Break','Saïd Business School','SBS Foyer','','','', ''],
['Saturday','10:30 AM','11:30 AM','1:00','Special sessions','Saïd Business School','Rhodes Trust; LT4','','','', ''],
['Saturday','11:35 AM','12:45 PM','1:10','Concurrent paper and panel sessions','Saïd Business School','Various','','','', ''],
['Saturday','12:45 PM','2:00 PM','1:15','Lunch and Award Presentations','Saïd Business School','SBS Foyer','','','', '']]
overview_df=pd.DataFrame(overview_rows, columns=['Weekday','Time Start','Time End','Duration','Session','Building','Room','excursion_id','excursion_option','meeting_point','description'])

# ---------- bios from tables ----------
old_bios=pd.read_csv(BASE/'bios.csv', dtype=str, keep_default_na=False)
bios_map={r['person_id']:r.to_dict() for _,r in old_bios.iterrows()}
# manual ordered ids/person names from master table rows
name_to_id={r['name']:r['person_id'] for _,r in old_bios.iterrows()}
# add common variants
name_to_id.update({'The Rt Hon Lord Hague of Richmond':'lord-william-hague','Moderator: Dr Monica Gorman':'monica-gorman','Professor Emeritus Sir Mike Gregory CBE, FREng.':'sir-mike-gregory','Dr. Markus Felgenhauer':'markus-felgenhauer','Jagjit Singh Srai':'jagjit-srai','Edward Anderson':'edward-anderson','Nitin Joglekar':'nitin-joglekar','Sebastian Weiske':'sebastian-weiske','Julia Pyke CBE':'julia-pyke','Jim Hall FREng FRS':'jim-hall','Alison Baptiste CBE CEng FICE':'alison-baptiste','Chetan Kotur FREng,':'chetan-kotur','Daniel Erian Armanios':'daniel-armanios','Mehdi Montakhabi':'mehdi-montakhabi','Dr Paul Bate':'paul-bate','Rob Desborough':'rob-desborough','Nigel Chandler':'nigel-chandler','Raja Roy':'raja-roy','Angela Garcia Calvo':'angela-garcia-calvo','Diane Coyle':'diane-coyle','Annabelle Gawer':'annabelle-gawer','Helena Malikova':'helena-malikova','John Gray':'john-gray','Damien Holly':'damien-holly','Mujaheed Shaikh':'mujaheed-shaikh','Travis Mosier':'travis-mosier','Saurabh Bansal':'saurabh-bansal','Laura Dupin':'laura-dupin','Juliane Reinecke':'juliane-reinecke'})
# Extract bio cells from tables 3 onwards. This updates existing bios only if a recognizable name is found.
for ti in range(3, min(len(doc.tables),13)):
    for row in doc.tables[ti].rows:
        text=clean(row.cells[-1].text)
        if not text: continue
        t=text.replace('Moderator:  ','').replace('Moderator: ','')
        # Person name before ' is ', or special title at start
        m=re.match(r'(.+?)\s+is\s+', t)
        nm=m.group(1).strip() if m else t.split('|')[0].split('.')[0].strip()
        # Remove obvious title suffix after comma for Chetan
        nm=nm.strip()
        pid=name_to_id.get(nm)
        if not pid:
            # canonical match by existing names
            cn=norm(nm)
            for name,pid0 in name_to_id.items():
                if norm(name)==cn:
                    pid=pid0; break
        if pid and pid in bios_map:
            bios_map[pid]['bio']=t
            if not bios_map[pid].get('name') or bios_map[pid]['name'] in ['XXX','YYY','Drone 1','Drone 2']:
                bios_map[pid]['name']=nm
# Make sure master shortened bios are applied
for pid,name,bio in [
('jagjit-srai','Jagjit Singh Srai', next((clean(row.cells[-1].text) for row in doc.tables[12].rows if 'Jagjit Singh Srai' in clean(row.cells[-1].text)), bios_map.get('jagjit-srai',{}).get('bio',''))),
('edward-anderson','Edward Anderson', next((clean(row.cells[-1].text) for row in doc.tables[12].rows if 'Edward Anderson' in clean(row.cells[-1].text)), bios_map.get('edward-anderson',{}).get('bio',''))),
('nitin-joglekar','Nitin Joglekar', next((clean(row.cells[-1].text) for row in doc.tables[12].rows if 'Nitin Joglekar' in clean(row.cells[-1].text)), bios_map.get('nitin-joglekar',{}).get('bio',''))),
]:
    if pid in bios_map:
        bios_map[pid]['name']=name; bios_map[pid]['bio']=bio
bios_df=pd.DataFrame(list(bios_map.values()))[old_bios.columns]

# ---------- bio-panels ----------
bio_panels=[]
name_pid={v['name']:k for k,v in bios_map.items()}
def pid_for_name(n):
    base=re.sub(r'\s*\([^)]*\)$','',n).strip()
    # remove titles for lookup
    for pid,row in bios_map.items():
        if norm(row['name'])==norm(base): return pid
    # known aliases
    aliases={'The Rt Hon Lord Hague of Richmond':'lord-william-hague','Professor Sir Mike Gregory':'sir-mike-gregory','Dr Monica Gorman':'monica-gorman','Dr. Markus Felgenhauer':'markus-felgenhauer','Dr Markus Felgenhauer':'markus-felgenhauer','Dr Paul Bate':'paul-bate','Mike Lewis':'mike-lewis'}
    return aliases.get(base, slug(base))
panel_id_map={'PL1':'opening-plenary','PL2':'value-chains-industrial-innovation-policy','SS1':'drones','SS2':'digital-stack','SS3':'space-market','SS4':'drug-shortages','SS5':'semiconductors','SS6':'infrastructure','SS7':'industry-studies-research','SS8':'global-supply-chains'}
for sp in specials:
    panid=panel_id_map[sp['id']]
    if sp['moderator']:
        bio_panels.append({'person_id':pid_for_name(sp['moderator']),'panel_id':panid,'role':'moderator' if sp['id']!='PL1' else 'moderator','panel_order':1})
    order=2
    for person in [x.strip() for x in sp['panelists'].split(';') if x.strip()]:
        role='speaker' if sp['category']=='Plenary' else 'panelist'
        if sp['id']=='PL1': role='speaker'; order=1
        bio_panels.append({'person_id':pid_for_name(person),'panel_id':panid,'role':role,'panel_order':order})
        order+=1
# ---------- committee.csv from master back matter ----------
committee_rows=[
['board',1,'Edward Anderson','President','University of Texas, Austin'],['board',2,'John Gray','Past President','The Ohio State University'],['board',3,'John Paul MacDuffie','Chief Fiscal Officer','University of Pennsylvania'],['board',4,'Jeff Shockley','Treasurer','Virginia Commonwealth University'],['board',5,'Jeff Furman','Early Career Development Committee','Boston University'],['board',6,'Raja Roy','Awards','New Jersey Institute of Technology'],['board',7,'Andrew Reamer','Industrial Policy','George Washington University'],['board',8,'Monica Gorman','Industrial Policy','Crowell Global Advisors'],['board',9,'Benn Lawson','Non-U.S. Strategy and Programming','University of Oxford'],['board',10,'Darcy Fudge Kamal','Membership','California State University, Sacramento'],['board',11,'Renae Sullivan','Program Manager','Industry Studies Association'],
['oxcc',1,'Benn Lawson','2026 International Conference Chair','University of Oxford'],['oxcc',2,'Daniel Armanios','Local Organising Committee member','University of Oxford'],['oxcc',3,'Federica De Stefano','Local Organising Committee member','University of Oxford'],['oxcc',4,'Matthew Amengual','Local Organising Committee member','University of Oxford'],['oxcc',5,'Edward Anderson','President','University of Texas'],['oxcc',6,'John Gray','Past President','The Ohio State University'],['oxcc',7,'John Paul Helveston','Conference Chair 2026','George Washington University'],['oxcc',8,'Renae Sullivan','Program Manager','Industry Studies Association'],
['stream_chairs',1,'Angela Garcia Calvo','Public Policy & Global Competitiveness','University of Reading'],['stream_chairs',2,'Federica De Stefano','Labor Markets, Organizations, and the Future of Work','University of Oxford'],['stream_chairs',3,'Laura Dupin','Innovation, Entrepreneurship, and AI-Driven Transformation','University of Amsterdam Business School'],['stream_chairs',4,'Guendalina Anzolin & Keno Haverkamp','General Industry Studies','University of Modena; University of Cambridge'],['stream_chairs',5,'David Reiner','Sustainable Innovation, Energy, and Mobility','University of Cambridge'],['stream_chairs',6,'Oliver von Dzengelevski','Operations, Supply Chain, and AI-Enhanced Industry 4.0','ETH Zurich'],['stream_chairs',7,'Rossella Salandra','Healthcare Systems, Biotechnology, and Pharmaceuticals','University of Bath']]
committee_df=pd.DataFrame(committee_rows, columns=['group','sort_order','name','role','affiliation'])

# ---------- awards.csv ----------
awards_df=pd.read_csv(BASE/'awards.csv', dtype=str, keep_default_na=False)
awards_df.loc[awards_df['award'].str.contains('Babbage',case=False,na=False),'awards_committee']='Sir Mike Gregory (University of Cambridge); Roberto Scazzieri (University of Bologna); David Leal (University of Cambridge)'
# ---------- excursions ----------
exc_df=pd.DataFrame([
{'excursion_id':'EX1','time_range':'7:45am-12:00pm','activity':'Aston Martin Racing F1 Technology Campus','org_panel_title':'Silverstone, Towcester. An exclusive behind-the-scenes visit to Aston Martin Aramco F1 Team’s state-of-the-art Technology Campus at Silverstone. The facility brings together design, engineering, manufacturing, aerodynamics, race support and commercial operations within one of the most advanced environments in world motorsport. Participants will gain a rare insight into how a Formula One car is conceived, designed, tested, manufactured, and continuously improved.','speaker_name':'','speaker_role':''},
{'excursion_id':'EX2','time_range':'8:00am-12:00pm','activity':'HR Wallingford','org_panel_title':"Wallingford, Oxford. A behind-the-scenes visit to one of the world's leading centres for water, environmental, and climate resilience research. Participants will tour HR Wallingford's unique research facilities, which combine large-scale physical modelling with advanced digital simulation to tackle complex challenges in flood risk, coastal protection, offshore energy and critical infrastructure.",'speaker_name':'','speaker_role':''},
{'excursion_id':'EX3','time_range':'10:00am-12:00pm','activity':'Walking Tour of Oxford','org_panel_title':'Depart Radcliffe Camera, 10:00am. Drop off at Saïd Business School, 12:00pm. A guided walking tour through Oxford’s historic city centre, introducing participants to the colleges, libraries, streets, and civic spaces that have shaped the University and city. The tour connects Oxford’s academic traditions with wider themes of knowledge, institutions, science, and place.','speaker_name':'','speaker_role':''}])
# ---------- guests.csv clean known encoding issue and panel changes ----------
guests_df=pd.read_csv(BASE/'guests.csv', dtype=str, keep_default_na=False)
guests_df['name']=guests_df['name'].str.replace('Fran├žois','François', regex=False)
guests_df['affiliation']=guests_df['affiliation'].str.replace('Oxford University','University of Oxford', regex=False)

# ---------- write files ----------
def write(df, filename):
    df.to_csv(OUT/filename,index=False,encoding='utf-8-sig')
write(overview_df,'overview.csv')
write(slot_df,'session-slots.csv')
write(panel_df,'panels.csv')
write(bios_df,'bios.csv')
write(pd.DataFrame(bio_panels),'bio-panels.csv')
write(pd.DataFrame(schairs),'session-chairs.csv')
write(sid_df,'session-ids.csv')
write(schedule_df,'schedule.csv')
write(committee_df,'committee.csv')
write(awards_df,'awards.csv')
write(exc_df,'excursion-program.csv')
write(guests_df,'guests.csv')
# Copy unchanged sources that feed app / retain context
for fn in ['submissions.csv','registrants.csv','change-log.csv']:
    shutil.copy(BASE/fn, OUT/fn)
# Comparison report
files=['overview.csv','session-slots.csv','panels.csv','bios.csv','bio-panels.csv','session-chairs.csv','session-ids.csv','schedule.csv','committee.csv','awards.csv','excursion-program.csv','guests.csv','submissions.csv','registrants.csv','change-log.csv']
comparison=[]
for fn in files:
    old=BASE/fn
    new=OUT/fn
    old_rows=sum(1 for _ in open(old,encoding='utf-8-sig'))-1 if old.exists() else None
    new_rows=sum(1 for _ in open(new,encoding='utf-8-sig'))-1
    comparison.append({'file':fn,'old_rows':old_rows,'new_rows':new_rows,'status':'updated' if fn not in ['submissions.csv','registrants.csv'] else 'copied unchanged'})
comp_df=pd.DataFrame(comparison)
write(comp_df,'update-summary.csv')
# Validation report
validation={
    'master_doc':'Programme Book v7 Linked.docx',
    'paper_sessions_extracted':len(paper_sessions),
    'paper_rows_extracted_from_master':len(extracted_papers),
    'schedule_rows':len(schedule_df),
    'session_id_rows':len(sid_df),
    'unmatched_papers_count':len(unmatched),
    'unmatched_papers':unmatched,
    'known_master_inconsistencies':["Saturday special-session rooms conflict: front overview lists Industry Studies Research in Rhodes Trust and Supply Chains in LT4; detailed headings list Industry Studies Research in NMLT and Supply Chains in Rhodes Trust. Updated CSVs use front overview rooms for attendee-facing schedule."],
    'sessions_without_chair':[s['session_id'] for s in paper_sessions if not s['session_chair']],
    'generated_files':files+['update-summary.csv','validation-report.json']
}
(OUT/'validation-report.json').write_text(json.dumps(validation,ensure_ascii=False,indent=2),encoding='utf-8')
# Zip
zip_path=BASE/'updated_csvs_from_programme_book_v7.zip'
if zip_path.exists(): zip_path.unlink()
with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED) as z:
    for p in OUT.rglob('*'):
        z.write(p,p.relative_to(OUT.parent))
print(json.dumps(validation,ensure_ascii=False,indent=2))
print('ZIP', zip_path)
