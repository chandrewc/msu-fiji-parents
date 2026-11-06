import Stripe from 'npm:stripe@23.0.0';
import {createClient} from 'npm:@supabase/supabase-js@2.99.1';
import {NETWORK_ORIGIN,ORIGINS,ACCOUNT_ID,parseDonation,checkoutParameters,donationConfig,matchesGoal} from '../_shared/donations.ts';
Deno.serve(async(req)=>{
 const origin=req.headers.get('origin')||'';
 const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':ORIGINS.has(origin)?origin:NETWORK_ORIGIN,'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin'};
 const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({error:'Method not allowed'},405);
 if(origin&&!ORIGINS.has(origin))return reply({error:'Origin not allowed'},403);
 try{
 const auth=req.headers.get('authorization')||'';if(!auth.startsWith('Bearer '))return reply({error:'Sign in required'},401);
 const db=createClient(Deno.env.get('SUPABASE_URL'),Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:{user},error}=await db.auth.getUser(auth.slice(7));if(error||!user)return reply({error:'Sign in required'},401);
 const member=await db.from('parents').select('approved,rejected,deactivated_at,profile_complete,role').eq('user_id',user.id).single();
 if(member.error||!member.data?.approved||member.data.rejected||member.data.deactivated_at||!member.data.profile_complete)return reply({error:'Approved parent access required'},403);
 const input=await req.json();const config=donationConfig(n=>Deno.env.get(n));
 // A protected administrator may verify live configuration without a charge.
 // Never return a checkout URL; immediately expire the unpaid $1 session.
 if(['verify_configuration','verification_status'].includes(input.action)){
 if(member.data.role!=='super_admin')return reply({error:'Super administrator required'},403);
 const flags={key_configured:/^(rk|sk)_live_/.test(config.key||''),webhook_configured:!!config.secret,account_matches:false,charges_enabled:false,signed_webhook_verified:false};
 if(!config.ready)return reply({...flags,verified:false});
 const verifier=new Stripe(config.key,{apiVersion:'2026-09-30.endive',maxNetworkRetries:2});
 const account=await verifier.accounts.retrieve();flags.account_matches=account.id===ACCOUNT_ID;flags.charges_enabled=account.charges_enabled===true;
 if(!flags.account_matches||!flags.charges_enabled)return reply({...flags,verified:false});
 if(input.action==='verification_status'){
 if(!/^[0-9a-f-]{36}$/i.test(input.donation_id||''))return reply({error:'Invalid verification reference'},400);
 const found=await db.from('stripe_donations').select('id,status,checkout_session_id').eq('id',input.donation_id).eq('member_id',user.id).eq('verification',true).single();
 if(found.error)return reply({error:'Verification not found'},404);
 const events=await db.from('stripe_donation_events').select('event_id').eq('donation_id',found.data.id).limit(1);
 flags.signed_webhook_verified=!events.error&&!!events.data?.length&&found.data.status==='expired';
 if(flags.signed_webhook_verified){const saved=await db.from('portal_settings').update({checkout_verified:true,verified_at:new Date().toISOString()}).eq('id',true);if(saved.error)throw saved.error;}
 return reply({...flags,verified:flags.signed_webhook_verified});
 }
 const donation={id:crypto.randomUUID(),member_id:user.id,amount_cents:100,purpose:'Unpaid configuration verification',fund:'parents',portal:'parents',livemode:true,verification:true};
 const inserted=await db.from('stripe_donations').insert(donation);if(inserted.error)throw inserted.error;
 const session=await verifier.checkout.sessions.create(checkoutParameters(donation,user.id),{idempotencyKey:'parents-verification-'+donation.id});
 if(!session.livemode||session.amount_total!==100||session.currency!=='usd'||session.metadata?.fund!=='parents'||session.metadata?.portal!=='parents')throw Error('Verification mismatch');
 const saved=await db.from('stripe_donations').update({checkout_session_id:session.id}).eq('id',donation.id);if(saved.error)throw saved.error;
 const expired=await verifier.checkout.sessions.expire(session.id);if(expired.status!=='expired')throw Error('Session not expired');
 return reply({...flags,verified:false,awaiting_webhook:true,donation_id:donation.id});
 }

 const gate=await db.from('portal_settings').select('checkout_verified').eq('id',true).single();
 let ready=config.ready&&config.enabled&&!gate.error&&gate.data?.checkout_verified===true;
 const stripe=config.ready?new Stripe(config.key,{apiVersion:'2026-09-30.endive',maxNetworkRetries:2}):null;
 if(ready){try{const account=await stripe.accounts.retrieve();ready=account.id===ACCOUNT_ID&&account.charges_enabled===true;}catch{ready=false;}}
 if(input.action==='status')return reply({ready,mode:'live'});
 if(!ready)return reply({error:'Online giving is not available yet.'},503);
 if(input.expected_mode!=='live')return reply({error:'Refresh before continuing.'},409);
 let parsed;try{parsed=parseDonation(input);}catch(e){return reply({error:e.message},400);}
 let goal=null;
 if(parsed.goalId){const selected=await db.from('donation_goals').select('id,title,active').eq('id',parsed.goalId).single();if(selected.error||!selected.data?.active)return reply({error:'This goal is no longer accepting donations. Choose another goal.'},409);goal=selected.data;}
 const pending={id:parsed.requestId,member_id:user.id,amount_cents:parsed.cents,purpose:parsed.purpose,goal_id:goal?.id||null,goal_title:goal?.title||'',fund:'parents',portal:'parents',livemode:true};
 const insert=await db.from('stripe_donations').insert(pending);if(insert.error&&insert.error.code!=='23505')throw insert.error;
 const found=await db.from('stripe_donations').select('*').eq('id',pending.id).eq('member_id',user.id).single();const donation=found.data;
 if(found.error||!donation||donation.amount_cents!==pending.amount_cents||donation.purpose!==pending.purpose||(donation.goal_id||null)!==pending.goal_id||donation.fund!=='parents'||donation.portal!=='parents'||donation.livemode!==true||donation.status!=='pending')return reply({error:'Start a new donation.'},409);
 const session=donation.checkout_session_id?await stripe.checkout.sessions.retrieve(donation.checkout_session_id):await stripe.checkout.sessions.create(checkoutParameters(donation,user.id),{idempotencyKey:'parents-'+donation.id});
 if(session.status!=='open'||!session.livemode||session.client_reference_id!==donation.id||session.amount_total!==donation.amount_cents||session.currency!=='usd'||session.metadata?.fund!=='parents'||session.metadata?.portal!=='parents'||session.metadata?.donation_id!==donation.id||session.metadata?.member_id!==user.id||!matchesGoal(donation,session.metadata)||!session.url?.startsWith('https://checkout.stripe.com/'))return reply({error:'Checkout verification failed.'},409);
 if(!donation.checkout_session_id){const saved=await db.from('stripe_donations').update({checkout_session_id:session.id}).eq('id',donation.id);if(saved.error)throw saved.error;}
 return reply({url:session.url,mode:'live',donation_id:donation.id});
 }catch{return reply({error:'Unable to open secure checkout. Please try again later.'},502);}
});
