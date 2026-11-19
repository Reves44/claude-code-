// scanHub.js
// The body scan is the hub of the app. Every new scan:
//   1. is saved to scan history (with its photos)
//   2. recalculates food goals (protein, calories, fat, carbs, sugar, fiber)
//   3. rebuilds the weekly workout plan for the Fitness page
//   4. tells every subscribed page (Food, Fitness, History) to update
//
// Plain JavaScript, no dependencies. Works in React Native, React, or any JS app.

// ---------------------------------------------------------------------------
// Storage: pass in AsyncStorage (React Native) or a localStorage wrapper (web).
// ---------------------------------------------------------------------------
const STORAGE_KEY = 'mur.scanHub.v1';

const memoryStorage = (() => {
  const m = {};
  return { getItem: async k => m[k] ?? null, setItem: async (k, v) => { m[k] = v; } };
})();

// ---------------------------------------------------------------------------
// Food goals
// ---------------------------------------------------------------------------
const LB_TO_KG = 0.453592;
const IN_TO_CM = 2.54;

const ACTIVITY = { sedentary: 1.2, light: 1.375, moderate: 1.55, very: 1.725 };

// How much to eat above or below maintenance for each goal
const GOAL_CALORIE_SHIFT = { lose_fat: -0.20, recomp: -0.05, maintain: 0, build_muscle: 0.10 };

/**
 * Work out daily food goals from a scan and the user's profile.
 * Protein = 1 g per lb of body weight (a 160 lb scan gives a 160 g protein goal).
 */
export function calculateFoodGoals(scan, profile) {
  const weightLb = scan.weightLb;
  const weightKg = weightLb * LB_TO_KG;
  const goal = profile.goal || 'maintain';

  // Resting calories: use lean mass when the scan gives body fat (more accurate),
  // otherwise use height, age and sex.
  let bmr;
  if (scan.bodyFatPct) {
    const leanKg = weightKg * (1 - scan.bodyFatPct / 100);
    bmr = 370 + 21.6 * leanKg; // Katch-McArdle
  } else {
    const heightCm = profile.heightIn * IN_TO_CM;
    bmr = 10 * weightKg + 6.25 * heightCm - 5 * profile.age + (profile.sex === 'female' ? -161 : 5); // Mifflin-St Jeor
  }

  const maintenance = bmr * (ACTIVITY[profile.activity] || ACTIVITY.moderate);
  const floor = profile.sex === 'female' ? 1200 : 1500;
  const calories = Math.max(floor, Math.round(maintenance * (1 + GOAL_CALORIE_SHIFT[goal]) + (profile.calorieAdjust || 0)));

  const proteinG = Math.round(weightLb * 1.0);
  const fatG = Math.round(Math.max(weightLb * 0.35, (calories * 0.20) / 9));
  const carbsG = Math.max(0, Math.round((calories - proteinG * 4 - fatG * 9) / 4));
  const sugarG = Math.round(Math.min((calories * (goal === 'lose_fat' ? 0.05 : 0.10)) / 4, profile.sex === 'female' ? 25 : 36));
  const fiberG = Math.round((calories / 1000) * 14);

  return { calories, proteinG, fatG, carbsG, sugarG, fiberG, maintenance: Math.round(maintenance), goal };
}

// ---------------------------------------------------------------------------
// Workouts
// ---------------------------------------------------------------------------
const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const LIFTS = {
  push: ['Bench Press', 'Overhead Press', 'Incline Dumbbell Press', 'Lateral Raise', 'Triceps Pushdown'],
  pull: ['Pull-Up or Lat Pulldown', 'Barbell Row', 'Seated Cable Row', 'Face Pull', 'Dumbbell Curl'],
  legs: ['Back Squat', 'Romanian Deadlift', 'Leg Press', 'Walking Lunge', 'Standing Calf Raise'],
  upper: ['Incline Bench Press', 'Chest-Supported Row', 'Dumbbell Shoulder Press', 'Lat Pulldown', 'Hammer Curl'],
  lower: ['Deadlift', 'Front Squat or Goblet Squat', 'Leg Curl', 'Bulgarian Split Squat', 'Plank'],
  full: ['Squat', 'Bench Press', 'Barbell Row', 'Romanian Deadlift', 'Plank'],
};

const CARDIO = {
  zone2: { name: 'Steady Cardio', items: ['35–45 min incline walk, bike or jog at a pace you can still talk'] },
  hiit: { name: 'Intervals', items: ['5 min warm-up', '8 × 30 sec hard / 90 sec easy', '5 min cool-down'] },
};

// Which day does what, for each goal
const SPLITS = {
  build_muscle: ['push', 'pull', 'legs', 'rest', 'upper', 'lower', 'rest'],
  lose_fat:     ['upper', 'zone2', 'lower', 'hiit', 'full', 'zone2', 'rest'],
  recomp:       ['full', 'zone2', 'upper', 'rest', 'lower', 'zone2', 'rest'],
  maintain:     ['full', 'rest', 'full', 'zone2', 'full', 'rest', 'rest'],
};

const SETS_REPS = { build_muscle: '4 × 8–12', lose_fat: '3 × 10–12', recomp: '4 × 6–10', maintain: '3 × 8–10' };

/** Build a 7-day plan for the Fitness page from the scan and goal. */
export function buildWeeklyWorkouts(scan, profile, extraCardioDays = 0) {
  const goal = profile.goal || 'maintain';
  const split = [...SPLITS[goal]];

  // If the hub decided progress is stalling, swap rest days for steady cardio.
  for (let i = 0, added = 0; i < split.length && added < extraCardioDays; i++) {
    if (split[i] === 'rest') { split[i] = 'zone2'; added++; }
  }

  return DAYS.map((day, i) => {
    const key = split[i];
    if (key === 'rest') return { day, type: 'rest', name: 'Rest', exercises: [] };
    if (CARDIO[key]) return { day, type: 'cardio', name: CARDIO[key].name, exercises: CARDIO[key].items.map(n => ({ name: n })) };
    return {
      day,
      type: 'strength',
      name: key === 'full' ? 'Full Body Day' : key[0].toUpperCase() + key.slice(1) + ' Day',
      exercises: LIFTS[key].map(name => ({ name, setsReps: name === 'Plank' ? '3 × 45 sec' : SETS_REPS[goal] })),
      fromScanId: scan.id,
    };
  });
}

// ---------------------------------------------------------------------------
// Adapting between scans
// ---------------------------------------------------------------------------
/**
 * Compare the new scan with the last one and nudge the plan.
 * Losing fat too slowly: eat 150 less and add a cardio day.
 * Losing too fast (over 1% a week): eat 150 more so muscle isn't lost.
 * Building muscle but not gaining: eat 150 more.
 */
export function adaptToProgress(prevScan, newScan, profile) {
  const adjust = { calorieAdjust: profile.calorieAdjust || 0, extraCardioDays: profile.extraCardioDays || 0, note: null };
  if (!prevScan) return adjust;

  const weeks = Math.max(0.5, (new Date(newScan.date) - new Date(prevScan.date)) / (7 * 864e5));
  const pctPerWeek = ((newScan.weightLb - prevScan.weightLb) / prevScan.weightLb) * 100 / weeks;

  if (profile.goal === 'lose_fat') {
    if (pctPerWeek > -0.25) {
      adjust.calorieAdjust -= 150;
      adjust.extraCardioDays = Math.min(2, adjust.extraCardioDays + 1);
      adjust.note = 'Weight loss slowed, so calories dropped by 150 and a cardio day was added.';
    } else if (pctPerWeek < -1) {
      adjust.calorieAdjust += 150;
      adjust.note = 'You are losing faster than 1% a week, so calories went up by 150 to protect muscle.';
    }
  } else if (profile.goal === 'build_muscle' && pctPerWeek < 0.1) {
    adjust.calorieAdjust += 150;
    adjust.note = 'Weight is not going up, so calories went up by 150.';
  }
  return adjust;
}

// ---------------------------------------------------------------------------
// The hub
// ---------------------------------------------------------------------------
export function createScanHub(storage = memoryStorage) {
  let state = {
    profile: { goal: 'maintain', sex: 'male', age: 21, heightIn: 70, activity: 'moderate', calorieAdjust: 0, extraCardioDays: 0 },
    scans: [],          // newest last; each scan keeps its photo URIs
    foodGoals: null,    // read by the Food page
    workouts: [],       // read by the Fitness page (7 days)
    lastNote: null,     // what changed on the last scan, to show the user
  };
  const listeners = new Set();

  const emit = () => listeners.forEach(fn => fn(state));
  const persist = () => storage.setItem(STORAGE_KEY, JSON.stringify(state));

  return {
    /** Load saved data. Call once when the app starts. */
    async load() {
      const raw = await storage.getItem(STORAGE_KEY);
      if (raw) state = { ...state, ...JSON.parse(raw) };
      emit();
      return state;
    },

    getState: () => state,

    /** Pages call this to re-render whenever a scan changes anything. Returns an unsubscribe function. */
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },

    /** Update goal, age, height, sex or activity, then rebuild everything from the latest scan. */
    async setProfile(changes) {
      state = { ...state, profile: { ...state.profile, ...changes } };
      const latest = state.scans[state.scans.length - 1];
      if (latest) {
        state.foodGoals = calculateFoodGoals(latest, state.profile);
        state.workouts = buildWeeklyWorkouts(latest, state.profile, state.profile.extraCardioDays);
      }
      await persist(); emit();
    },

    /**
     * Call this when a body scan finishes.
     * scan = { weightLb: 160, bodyFatPct: 18, measurements: { waistIn: 33 }, photoUris: ['file://...'] }
     */
    async addScan(scan) {
      const full = { id: String(Date.now()), date: new Date().toISOString(), photoUris: [], ...scan };
      const prev = state.scans[state.scans.length - 1];

      const adjust = adaptToProgress(prev, full, state.profile);
      const profile = { ...state.profile, calorieAdjust: adjust.calorieAdjust, extraCardioDays: adjust.extraCardioDays };

      state = {
        ...state,
        profile,
        scans: [...state.scans, full],
        foodGoals: calculateFoodGoals(full, profile),
        workouts: buildWeeklyWorkouts(full, profile, adjust.extraCardioDays),
        lastNote: adjust.note,
      };
      await persist(); emit();
      return state;
    },

    /** Past scans with their photos, newest first, for the history screen. */
    getHistory: () => [...state.scans].reverse(),

    /** The workout for one day of the week, e.g. getWorkoutForDay('Wed'). */
    getWorkoutForDay: day => state.workouts.find(w => w.day === day) || null,
  };
}
