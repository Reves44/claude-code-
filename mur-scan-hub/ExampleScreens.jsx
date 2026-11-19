// ExampleScreens.jsx
// Example React Native screens wired to the scan hub. Copy the parts you need
// into your existing Body Scan, Food and Fitness screens.
import React, { useState } from 'react';
import { View, Text, Image, Pressable, ScrollView, FlatList, StyleSheet } from 'react-native';
import { scanHub, useScanHub } from './useScanHub';

const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// ---------------------------------------------------------------------------
// 1. Body Scan screen (the hub)
// ---------------------------------------------------------------------------
export function BodyScanScreen({ navigation }) {
  const { scans, foodGoals, workouts, lastNote } = useScanHub();
  const latest = scans[scans.length - 1];

  // Call this from wherever your scan finishes:
  async function onScanComplete(result) {
    await scanHub.addScan({
      weightLb: result.weightLb,          // e.g. 160
      bodyFatPct: result.bodyFatPct,      // e.g. 18
      measurements: result.measurements,  // e.g. { waistIn: 33, chestIn: 40 }
      photoUris: result.photoUris,        // the images taken during the scan
    });
    // Food and Fitness pages update on their own from here.
  }

  return (
    <ScrollView style={s.page}>
      <Text style={s.h1}>Body Scan</Text>
      {latest ? (
        <View style={s.card}>
          <Text style={s.big}>{latest.weightLb} lb</Text>
          {latest.bodyFatPct ? <Text style={s.sub}>{latest.bodyFatPct}% body fat</Text> : null}
          <Text style={s.sub}>Scanned {new Date(latest.date).toLocaleDateString()}</Text>
        </View>
      ) : <Text style={s.sub}>Do your first scan to set your food goals and workouts.</Text>}

      {lastNote ? <Text style={s.note}>{lastNote}</Text> : null}

      {foodGoals && (
        <Pressable style={s.card} onPress={() => navigation.navigate('Food')}>
          <Text style={s.h2}>Today's food goals</Text>
          <Text style={s.row}>Calories {foodGoals.calories}</Text>
          <Text style={s.row}>Protein {foodGoals.proteinG} g · Carbs {foodGoals.carbsG} g · Fat {foodGoals.fatG} g</Text>
          <Text style={s.row}>Sugar under {foodGoals.sugarG} g · Fiber {foodGoals.fiberG} g</Text>
        </Pressable>
      )}

      {workouts.length > 0 && (
        <View style={s.card}>
          <Text style={s.h2}>This week's workouts</Text>
          <View style={s.week}>
            {workouts.map(w => (
              <Pressable key={w.day} style={[s.day, w.type === 'rest' && s.rest]} onPress={() => navigation.navigate('Fitness', { day: w.day })}>
                <Text style={s.dayText}>{w.day}</Text>
              </Pressable>
            ))}
          </View>
        </View>
      )}

      <Pressable style={s.button} onPress={() => navigation.navigate('ScanHistory')}>
        <Text style={s.buttonText}>See past scans</Text>
      </Pressable>
    </ScrollView>
  );
}

// ---------------------------------------------------------------------------
// 2. Food page: goals always come from the latest scan
// ---------------------------------------------------------------------------
export function FoodGoalsCard({ eatenToday }) {
  const { foodGoals } = useScanHub();
  if (!foodGoals) return <Text style={s.sub}>Do a body scan to set your goals.</Text>;
  const rows = [
    ['Calories', eatenToday.calories, foodGoals.calories, ''],
    ['Protein', eatenToday.proteinG, foodGoals.proteinG, 'g'],
    ['Carbs', eatenToday.carbsG, foodGoals.carbsG, 'g'],
    ['Fat', eatenToday.fatG, foodGoals.fatG, 'g'],
    ['Sugar', eatenToday.sugarG, foodGoals.sugarG, 'g'],
  ];
  return (
    <View style={s.card}>
      {rows.map(([name, eaten, goal, unit]) => (
        <Text key={name} style={s.row}>{name}: {eaten}{unit} / {goal}{unit}</Text>
      ))}
    </View>
  );
}

// ---------------------------------------------------------------------------
// 3. Fitness page: tap a day to see the workout the scan built
// ---------------------------------------------------------------------------
export function FitnessScreen({ route }) {
  const { workouts } = useScanHub();
  const today = DAYS[(new Date().getDay() + 6) % 7];
  const [day, setDay] = useState(route?.params?.day || today);
  const workout = workouts.find(w => w.day === day);

  return (
    <ScrollView style={s.page}>
      <View style={s.week}>
        {DAYS.map(d => (
          <Pressable key={d} style={[s.day, d === day && s.daySelected]} onPress={() => setDay(d)}>
            <Text style={s.dayText}>{d}</Text>
          </Pressable>
        ))}
      </View>
      {!workout ? <Text style={s.sub}>Do a body scan to get your workouts.</Text> : (
        <View style={s.card}>
          <Text style={s.h2}>{workout.name}</Text>
          {workout.exercises.length === 0
            ? <Text style={s.sub}>Rest and recover today.</Text>
            : workout.exercises.map(e => <Text key={e.name} style={s.row}>{e.name}{e.setsReps ? `  ${e.setsReps}` : ''}</Text>)}
        </View>
      )}
    </ScrollView>
  );
}

// ---------------------------------------------------------------------------
// 4. Past scans with their photos
// ---------------------------------------------------------------------------
export function ScanHistoryScreen() {
  useScanHub();
  const history = scanHub.getHistory();
  return (
    <FlatList
      style={s.page}
      data={history}
      keyExtractor={item => item.id}
      ListEmptyComponent={<Text style={s.sub}>No scans yet.</Text>}
      renderItem={({ item }) => (
        <View style={s.card}>
          <Text style={s.h2}>{new Date(item.date).toLocaleDateString()} · {item.weightLb} lb{item.bodyFatPct ? ` · ${item.bodyFatPct}%` : ''}</Text>
          <ScrollView horizontal>
            {item.photoUris.map(uri => <Image key={uri} source={{ uri }} style={s.photo} />)}
          </ScrollView>
        </View>
      )}
    />
  );
}

const s = StyleSheet.create({
  page: { flex: 1, padding: 16, backgroundColor: '#0c0f14' },
  h1: { color: '#fff', fontSize: 28, fontWeight: '800', marginBottom: 12 },
  h2: { color: '#fff', fontSize: 17, fontWeight: '700', marginBottom: 8 },
  big: { color: '#fff', fontSize: 40, fontWeight: '800' },
  sub: { color: '#9aa3b2', fontSize: 14, marginVertical: 4 },
  note: { color: '#f0b35a', fontSize: 14, marginVertical: 8 },
  row: { color: '#e6e9ef', fontSize: 15, marginVertical: 3 },
  card: { backgroundColor: '#161b24', borderRadius: 12, padding: 14, marginVertical: 8 },
  week: { flexDirection: 'row', justifyContent: 'space-between', marginVertical: 8 },
  day: { paddingVertical: 10, paddingHorizontal: 8, borderRadius: 8, backgroundColor: '#22406e' },
  rest: { backgroundColor: '#2a2f3a' },
  daySelected: { backgroundColor: '#3fc596' },
  dayText: { color: '#fff', fontWeight: '700' },
  photo: { width: 110, height: 160, borderRadius: 8, marginRight: 8 },
  button: { backgroundColor: '#3fc596', borderRadius: 10, padding: 14, alignItems: 'center', marginVertical: 12 },
  buttonText: { color: '#06130e', fontWeight: '800', fontSize: 16 },
});
