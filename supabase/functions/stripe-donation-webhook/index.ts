import Stripe from 'npm:stripe@23.0.0';
import {createClient} from 'npm:@supabase/supabase-js@2.99.1';
import {donationConfig,ownsPortal} from '../_shared/donations.ts';
Deno.serve(async(req)=>{
 if(req.method!=='POST')return new Response('Method not allowed',{status:405});
 const config=donationConfig(n=>Deno.env.get(n));
 // Keep refund/event processing active even when checkout is disabled.
 if(!config.ready)return new Response('Not configured',{status:503});
 const stripe=new Stripe(config.key,{apiVersion:'2026-09-30.endive',maxNetworkRetries:2});let event;
 try{event=await stripe.webhooks.constructEventAsync(await req.text(),req.headers.get('stripe-signature')||'',config.secret,undefined,Stripe.createSubtleCryptoProvider());}catch{return new Response('Invalid signature',{status:400});}
 if(!event.livemode)return new Response('Ignored',{status:200});
 if(!['checkout.session.completed','checkout.session.async_payment_succeeded','checkout.session.async_payment_failed','checkout.session.expired','charge.refunded'].includes(event.type))return new Response('Ignored',{status:200});
 try{
 const object=event.data.object;let session=object,refunded=0,status;
 if(event.type==='charge.refunded'){
 const pi=typeof object.payment_intent==='string'?object.payment_intent:object.payment_intent?.id;
 if(!pi)return new Response('Ignored',{status:200});
 // Require both the session and underlying PaymentIntent to belong to this portal.
 const intent=await stripe.paymentIntents.retrieve(pi);if(!ownsPortal(intent.metadata))return new Response('Ignored',{status:200});
 session=(await stripe.checkout.sessions.list({payment_intent:pi,limit:1})).data[0];
 if(!session||!ownsPortal(session.metadata))return new Response('Ignored',{status:200});
 if(intent.metadata.donation_id!==session.metadata.donation_id||object.amount!==session.amount_total||object.currency!==session.currency||!object.livemode)throw Error('Refund mismatch');
 refunded=object.amount_refunded;status=refunded===object.amount?'refunded':'partially_refunded';
 }else{
 if(!ownsPortal(session.metadata))return new Response('Ignored',{status:200});
 if(event.type==='checkout.session.expired')status='expired';else if(event.type==='checkout.session.async_payment_failed')status='failed';else if(session.payment_status==='paid')status='paid';else return new Response('Awaiting payment',{status:200});
 }
 if(!session.livemode||!ownsPortal(session.metadata))return new Response('Ignored',{status:200});
 const db=createClient(Deno.env.get('SUPABASE_URL'),Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
 const found=await db.from('stripe_donations').select('*').eq('id',session.metadata.donation_id).single();const donation=found.data;
 if(found.error||!donation)throw Error('Donation not found');
 const pi=typeof session.payment_intent==='string'?session.payment_intent:session.payment_intent?.id;
 if(donation.fund!=='parents'||donation.portal!=='parents'||!donation.livemode||donation.member_id!==session.metadata.member_id||donation.checkout_session_id!==session.id||donation.amount_cents!==session.amount_total||donation.currency!==session.currency||(donation.payment_intent_id&&donation.payment_intent_id!==pi))return new Response('Donation mismatch',{status:400});
 const processed=await db.rpc('record_stripe_donation_event',{p_event_id:event.id,p_donation_id:donation.id,p_session_id:session.id,p_payment_intent_id:pi||null,p_status:status,p_refunded_cents:refunded});
 if(processed.error)throw processed.error;
 return new Response('OK',{status:200});
 }catch{return new Response('Processing failed; retry delivery',{status:500});}
});
