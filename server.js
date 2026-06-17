require('dotenv').config();
const express = require('express');
const Database = require('better-sqlite3');
const nodemailer = require('nodemailer');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// ── Stripe (load only if key present) ──────────────────────────────────────
let stripe = null;
if (process.env.STRIPE_SECRET_KEY && !process.env.STRIPE_SECRET_KEY.startsWith('sk_test_xxx')) {
  stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
}

// ── Twilio (load only if configured) ───────────────────────────────────────
let twilioClient = null;
if (process.env.TWILIO_ACCOUNT_SID && !process.env.TWILIO_ACCOUNT_SID.startsWith('ACxxx')) {
  twilioClient = require('twilio')(process.env.TWILIO_ACCOUNT_SID, process.env.TWILIO_AUTH_TOKEN);
}

// ── Database ────────────────────────────────────────────────────────────────
const db = new Database('./bookings.db');

db.exec(`
  CREATE TABLE IF NOT EXISTS bookings (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_name       TEXT NOT NULL,
    owner_phone      TEXT NOT NULL,
    owner_email      TEXT NOT NULL,
    pet_name         TEXT NOT NULL,
    breed            TEXT NOT NULL,
    service          TEXT NOT NULL,
    date             TEXT NOT NULL,
    time             TEXT NOT NULL,
    notes            TEXT,
    payment_status   TEXT DEFAULT 'pending',
    stripe_session   TEXT,
    created_at       DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS blocked_slots (
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    date  TEXT NOT NULL,
    time  TEXT NOT NULL,
    UNIQUE(date, time)
  );
`);

// ── Email ───────────────────────────────────────────────────────────────────
const mailer = nodemailer.createTransport({
  service: 'gmail',
  auth: { user: process.env.EMAIL_USER, pass: process.env.EMAIL_PASS },
});

async function sendEmail(to, subject, html) {
  if (!process.env.EMAIL_USER || process.env.EMAIL_USER.startsWith('your-')) return;
  try {
    await mailer.sendMail({ from: `"Pampered Paws Grooming" <${process.env.EMAIL_USER}>`, to, subject, html });
  } catch (e) {
    console.warn('Email send failed:', e.message);
  }
}

async function sendSMS(to, body) {
  if (!twilioClient || !to) return;
  try {
    await twilioClient.messages.create({ from: process.env.TWILIO_FROM_NUMBER, to, body });
  } catch (e) {
    console.warn('SMS send failed:', e.message);
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────
const ALL_SLOTS = [
  '9:30 AM','10:00 AM','10:30 AM','11:00 AM','11:30 AM',
  '12:00 PM','12:30 PM','1:00 PM','1:30 PM',
  '2:00 PM','2:30 PM','3:00 PM','3:30 PM','4:00 PM','4:30 PM',
];

function isOpenDay(dateStr) {
  const d = new Date(dateStr + 'T00:00:00');
  return [3, 4, 5].includes(d.getDay()); // Wed=3, Thu=4, Fri=5
}

function formatDate(dateStr) {
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('en-US', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  });
}

function confirmationEmail(b) {
  return `
  <div style="font-family:sans-serif;max-width:560px;margin:auto;background:#f7fbfa;border-radius:12px;overflow:hidden">
    <div style="background:linear-gradient(135deg,#264653,#2a9d8f);color:white;padding:32px 28px;text-align:center">
      <div style="font-size:2.5rem">🐾</div>
      <h1 style="margin:10px 0 4px;font-size:1.5rem">Booking Confirmed!</h1>
      <p style="opacity:.85;margin:0">Pampered Paws Grooming · Knoxville, TN</p>
    </div>
    <div style="padding:28px">
      <p style="margin:0 0 20px">Hi <strong>${b.owner_name}</strong>! We can't wait to pamper <strong>${b.pet_name}</strong>. Here are your appointment details:</p>
      <table style="width:100%;border-collapse:collapse;font-size:.95rem">
        <tr style="border-bottom:1px solid #e5e7eb"><td style="padding:10px 0;color:#5f7070;width:130px">Service</td><td style="padding:10px 0;font-weight:600">${b.service}</td></tr>
        <tr style="border-bottom:1px solid #e5e7eb"><td style="padding:10px 0;color:#5f7070">Date</td><td style="padding:10px 0;font-weight:600">${formatDate(b.date)}</td></tr>
        <tr style="border-bottom:1px solid #e5e7eb"><td style="padding:10px 0;color:#5f7070">Time</td><td style="padding:10px 0;font-weight:600">${b.time}</td></tr>
        <tr style="border-bottom:1px solid #e5e7eb"><td style="padding:10px 0;color:#5f7070">Pet</td><td style="padding:10px 0;font-weight:600">${b.pet_name} (${b.breed})</td></tr>
        ${b.notes ? `<tr><td style="padding:10px 0;color:#5f7070">Notes</td><td style="padding:10px 0">${b.notes}</td></tr>` : ''}
      </table>
      <div style="background:#e8f7f5;border-radius:8px;padding:16px;margin:20px 0;font-size:.88rem">
        <strong>📍 Location:</strong> 7544 Oak Ridge Hwy #2, Knoxville, TN 37931<br>
        <strong>📞 Questions?</strong> Call us at <a href="tel:8656925335" style="color:#2a9d8f">(865) 692-5335</a>
      </div>
      <p style="font-size:.85rem;color:#5f7070;margin:0">Please arrive 5 minutes early. If you need to reschedule, call us at least 24 hours in advance.</p>
    </div>
    <div style="background:#264653;color:rgba(255,255,255,.6);text-align:center;padding:16px;font-size:.8rem">
      Pampered Paws Grooming · 7544 Oak Ridge Hwy #2, Knoxville, TN 37931
    </div>
  </div>`;
}

function alertEmail(b) {
  return `
  <div style="font-family:sans-serif;max-width:500px;margin:auto">
    <h2 style="color:#264653">🐾 New Booking!</h2>
    <table style="width:100%;border-collapse:collapse;font-size:.95rem">
      <tr><td style="padding:8px 0;color:#5f7070;width:120px">Owner</td><td style="padding:8px 0"><strong>${b.owner_name}</strong> · <a href="tel:${b.owner_phone}">${b.owner_phone}</a> · ${b.owner_email}</td></tr>
      <tr><td style="padding:8px 0;color:#5f7070">Pet</td><td style="padding:8px 0">${b.pet_name} (${b.breed})</td></tr>
      <tr><td style="padding:8px 0;color:#5f7070">Service</td><td style="padding:8px 0">${b.service}</td></tr>
      <tr><td style="padding:8px 0;color:#5f7070">Date</td><td style="padding:8px 0">${formatDate(b.date)} at ${b.time}</td></tr>
      <tr><td style="padding:8px 0;color:#5f7070">Payment</td><td style="padding:8px 0">${b.payment_status}</td></tr>
      ${b.notes ? `<tr><td style="padding:8px 0;color:#5f7070">Notes</td><td style="padding:8px 0">${b.notes}</td></tr>` : ''}
    </table>
  </div>`;
}

// ── Middleware ────────────────────────────────────────────────────────────────
// Stripe webhook needs raw body — must come before express.json()
app.post('/api/webhook', express.raw({ type: 'application/json' }), async (req, res) => {
  if (!stripe) return res.sendStatus(400);
  let event;
  try {
    event = stripe.webhooks.constructEvent(req.body, req.headers['stripe-signature'], process.env.STRIPE_WEBHOOK_SECRET);
  } catch (e) {
    return res.status(400).send(`Webhook Error: ${e.message}`);
  }

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object;
    const b = JSON.parse(session.metadata.booking);
    db.prepare(`
      INSERT INTO bookings (owner_name,owner_phone,owner_email,pet_name,breed,service,date,time,notes,payment_status,stripe_session)
      VALUES (?,?,?,?,?,?,?,?,?,'paid',?)
    `).run(b.owner_name,b.owner_phone,b.owner_email,b.pet_name,b.breed,b.service,b.date,b.time,b.notes||'',session.id);

    await sendEmail(b.owner_email, '✅ Your Pampered Paws Appointment is Confirmed!', confirmationEmail(b));
    await sendEmail(process.env.BUSINESS_EMAIL, `New Booking – ${b.pet_name} (${b.service})`, alertEmail({ ...b, payment_status: 'paid' }));
    await sendSMS(process.env.BUSINESS_PHONE,
      `🐾 New booking!\n${b.pet_name} (${b.breed}) – ${b.service}\n${formatDate(b.date)} at ${b.time}\nOwner: ${b.owner_name} ${b.owner_phone}`);
  }

  res.json({ received: true });
});

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── API: available slots ──────────────────────────────────────────────────────
app.get('/api/slots', (req, res) => {
  const { date } = req.query;
  if (!date || !isOpenDay(date)) return res.json({ slots: [] });

  const booked = db.prepare(`SELECT time FROM bookings WHERE date=? AND payment_status != 'cancelled'`).all(date).map(r => r.time);
  const blocked = db.prepare(`SELECT time FROM blocked_slots WHERE date=?`).all(date).map(r => r.time);
  const taken = new Set([...booked, ...blocked]);
  const slots = ALL_SLOTS.map(t => ({ time: t, available: !taken.has(t) }));
  res.json({ slots });
});

// ── API: create booking (no payment, or payment-pending) ──────────────────────
app.post('/api/bookings', async (req, res) => {
  const { owner_name, owner_phone, owner_email, pet_name, breed, service, date, time, notes } = req.body;

  if (!owner_name || !owner_phone || !owner_email || !pet_name || !breed || !service || !date || !time)
    return res.status(400).json({ error: 'Missing required fields' });

  if (!isOpenDay(date))
    return res.status(400).json({ error: 'We are closed that day' });

  // Check slot still available
  const conflict = db.prepare(`SELECT id FROM bookings WHERE date=? AND time=? AND payment_status != 'cancelled'`).get(date, time);
  if (conflict) return res.status(409).json({ error: 'That time slot is no longer available' });

  const b = { owner_name, owner_phone, owner_email, pet_name, breed, service, date, time, notes: notes || '' };

  // If Stripe configured, create checkout session
  if (stripe) {
    try {
      const depositAmount = parseInt(process.env.DEPOSIT_AMOUNT || '2500');
      const session = await stripe.checkout.sessions.create({
        payment_method_types: ['card'],
        line_items: [{
          price_data: {
            currency: 'usd',
            product_data: {
              name: `${service} – ${pet_name}`,
              description: `Grooming deposit for ${formatDate(date)} at ${time}`,
              images: [],
            },
            unit_amount: depositAmount,
          },
          quantity: 1,
        }],
        mode: 'payment',
        success_url: `${process.env.BASE_URL || 'http://localhost:3000'}/success.html?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${process.env.BASE_URL || 'http://localhost:3000'}/#book`,
        customer_email: owner_email,
        metadata: { booking: JSON.stringify(b) },
      });
      return res.json({ url: session.url });
    } catch (e) {
      console.error('Stripe error:', e);
      return res.status(500).json({ error: 'Payment setup failed' });
    }
  }

  // No Stripe — save directly and send notifications
  db.prepare(`
    INSERT INTO bookings (owner_name,owner_phone,owner_email,pet_name,breed,service,date,time,notes,payment_status)
    VALUES (?,?,?,?,?,?,?,?,?,'confirmed')
  `).run(owner_name, owner_phone, owner_email, pet_name, breed, service, date, time, notes || '');

  await sendEmail(owner_email, '✅ Your Pampered Paws Appointment is Confirmed!', confirmationEmail(b));
  await sendEmail(process.env.BUSINESS_EMAIL, `New Booking – ${pet_name} (${service})`, alertEmail({ ...b, payment_status: 'confirmed' }));
  await sendSMS(process.env.BUSINESS_PHONE,
    `🐾 New booking!\n${pet_name} (${breed}) – ${service}\n${formatDate(date)} at ${time}\nOwner: ${owner_name} ${owner_phone}`);

  res.json({ success: true });
});

// ── API: verify Stripe session (for success page) ─────────────────────────────
app.get('/api/session/:id', async (req, res) => {
  if (!stripe) return res.status(404).json({ error: 'Stripe not configured' });
  try {
    const session = await stripe.checkout.sessions.retrieve(req.params.id);
    const b = JSON.parse(session.metadata.booking || '{}');
    res.json({ status: session.payment_status, booking: b });
  } catch (e) {
    res.status(404).json({ error: 'Session not found' });
  }
});

// ── Admin: list bookings (simple, password-free for now) ──────────────────────
app.get('/api/admin/bookings', (req, res) => {
  const rows = db.prepare(`SELECT * FROM bookings ORDER BY date, time`).all();
  res.json(rows);
});

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n🐾 Pampered Paws Grooming server running`);
  console.log(`   Local:  http://localhost:${PORT}`);
  console.log(`   Stripe: ${stripe ? '✅ configured' : '⚠️  not configured (bookings save directly)'}`);
  console.log(`   Email:  ${process.env.EMAIL_USER && !process.env.EMAIL_USER.startsWith('your-') ? '✅ configured' : '⚠️  not configured'}`);
  console.log(`   SMS:    ${twilioClient ? '✅ configured' : '⚠️  not configured'}\n`);
});
