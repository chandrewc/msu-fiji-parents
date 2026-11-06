export function chapterDate(value=new Date()){
 const parts=new Intl.DateTimeFormat('en-US',{timeZone:'America/Chicago',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(value);
 const part=type=>parts.find(p=>p.type===type).value;
 return part('year')+'-'+part('month')+'-'+part('day');
}
