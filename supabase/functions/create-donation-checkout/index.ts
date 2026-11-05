import Stripe from 'npm:stripe@23.0.0';
import {createClient} from 'npm:@supabase/supabase-js@2.99.1';
import {NETWORK_ORIGIN,ORIGINS,ACCOUNT_ID,parseDonation,checkoutParameters,donationConfig} from '../_shared/donations.ts';
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
 const member=await db.from('parents').select('approved,rejected,deactivated_at,profile_complete').eq('user_id',user.id).single();
 if(member.error||!member.data?.approved||member.data.rejected||member.data.deactivated_at||!member.data.profile_complete)return reply({error:'Approved parent access required'},403);
 const input=await req.json();const config=donationConfig(n=>Deno.env.get(n));
 const gate=await db.from('portal_settings').select('checkout_verified').eq('id',true).single();
 let ready=config.ready&&config.enabled&&!gate.error&&gate.data?.checkout_verified===true;
 const stripe=config.ready?new Stripe(config.key,{apiVersion:'2026-09-30.endive',maxNetworkRetries:2}):null;
 if(ready){try{const account=await stripe.accounts.retrieve();ready=account.id===ACCOUNT_ID&&account.charges_enabled===true;}catch{ready=false;}}
 if(input.action==='status')return reply({ready,mode:'live'});
 if(!ready)return reply({error:'Online giving is not available yet.'},503);
 if(input.expected_mode!=='live')return reply({error:'Refresh before continuing.'},409);
 let parsed;try{parsed=parseDonation(input);}catch(e){return reply({error:e.message},400);}
 const pending={id:parsed.requestId,member_id:user.id,amount_cents:parsed.cents,purpose:parsed.purpose,fund:'parents',portal:'parents',livemode:true};
 const insert=await db.from('stripe_donations').insert(pending);if(insert.error&&insert.error.code!=='23505')throw insert.error;
 const found=await db.from('stripe_donations').select('*').eq('id',pending.id).eq('member_id',user.id).single();const donation=found.data;
 if(found.error||!donation||donation.amount_cents!==pending.amount_cents||donation.purpose!==pending.purpose||donation.fund!=='parents'||donation.portal!=='parents'||donation.livemode!==true||donation.status!=='pending')return reply({error:'Start a new donation.'},409);
 const session=donation.checkout_session_id?await stripe.checkout.sessions.retrieve(donation.checkout_session_id):await stripe.checkout.sessions.create(checkoutParameters(donation,user.id),{idempotencyKey:'parents-'+donation.id});
 if(session.status!=='open'||!session.livemode||session.client_reference_id!==donation.id||session.amount_total!==donation.amount_cents||session.currency!=='usd'||session.metadata?.fund!=='parents'||session.metadata?.portal!=='parents'||session.metadata?.donation_id!==donation.id||session.metadata?.member_id!==user.id||!session.url?.startsWith('https://checkout.stripe.com/'))return reply({error:'Checkout verification failed.'},409);
 if(!donation.checkout_session_id){const saved=await db.from('stripe_donations').update({checkout_session_id:session.id}).eq('id',donation.id);if(saved.error)throw saved.error;}
 return reply({url:session.url,mode:'live',donation_id:donation.id});
 }catch{return reply({error:'Unable to open secure checkout. Please try again later.'},502);}
});
