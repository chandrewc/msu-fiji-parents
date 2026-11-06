export const NETWORK_ORIGIN='https://parents.msufiji.com';
export const ORIGINS=new Set([NETWORK_ORIGIN]);
export const ACCOUNT_ID='acct_1UVhQu0LKcs9BAsZ';
export function parseDonation(input) {
 const amount=String(input?.amount??'').trim();
 if(!/^(?:0|[1-9]\d{0,5})(?:\.\d{1,2})?$/.test(amount))throw Error('Enter a dollar amount with at most two decimal places.');
 const [whole,fraction='']=amount.split('.');const cents=Number(whole)*100+Number(fraction.padEnd(2,'0'));
 if(!Number.isSafeInteger(cents)||cents<100||cents>10000000)throw Error('Choose an amount between $1 and $100,000.');
 if(typeof input.purpose!=='string'||input.purpose.length>500)throw Error('The message must be 500 characters or fewer.');
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.request_id||''))throw Error('Start a new donation.');
 const goalId=input.goal_id==null||input.goal_id===''?null:input.goal_id;
 if(goalId!==null&&(typeof goalId!=='string'||! /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(goalId)))throw Error('Choose a valid donation goal.');
 return {cents,purpose:input.purpose.trim(),requestId:input.request_id,goalId};
}
export function checkoutParameters(donation,memberId){
 const metadata={fund:'parents',portal:'parents',donation_id:donation.id,member_id:memberId,...(donation.goal_id?{goal_id:donation.goal_id,goal_title:donation.goal_title}:{})};
 const label=donation.goal_id?'Parents Fund — '+donation.goal_title:'Sigma Mu Parents Fund';
 return {mode:'payment',submit_type:'donate',integration_identifier:'sigma_mu_parents_fund_qxpkmsva',client_reference_id:donation.id,
 line_items:[{price_data:{currency:'usd',unit_amount:donation.amount_cents,product_data:{name:label,description:label}},quantity:1}],
 automatic_tax:{enabled:false},allow_promotion_codes:false,metadata,payment_intent_data:{description:label,metadata},
 success_url:NETWORK_ORIGIN+'/?donation='+donation.id+'#donate',cancel_url:NETWORK_ORIGIN+'/?donation_cancelled=1#donate'};
}
export function donationConfig(env){const key=(env('STRIPE_PARENTS_LIVE_KEY')||'').trim(),secret=(env('STRIPE_PARENTS_WEBHOOK_SECRET')||'').trim();return {key,secret,ready:/^(rk|sk)_live_/.test(key||'')&&secret.startsWith('whsec_')&&(env('STRIPE_PARENTS_LIVE_ACCOUNT_ID')||'').trim()===ACCOUNT_ID,enabled:(env('STRIPE_PARENTS_CHECKOUT_ENABLED')||'').trim()==='true'};}
export function ownsPortal(metadata){return metadata?.fund==='parents'&&metadata?.portal==='parents'&&typeof metadata?.donation_id==='string'&&typeof metadata?.member_id==='string';}

export function matchesGoal(donation,metadata){return (donation.goal_id||'')===(metadata?.goal_id||'')&&(!donation.goal_id||donation.goal_title===metadata?.goal_title);}
