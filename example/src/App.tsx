import { useState } from 'react';
import {
  Platform,
  Pressable,
  SafeAreaView,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { CameraScreen } from './CameraScreen';
import { PhotoScreen } from './PhotoScreen';
import { SelfTestScreen } from './SelfTestScreen';

const TABS = ['Photo', 'Camera', 'Self-test'] as const;
type Tab = (typeof TABS)[number];

export default function App() {
  const [tab, setTab] = useState<Tab>('Photo');
  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.tabs}>
        {TABS.map(t => (
          <Pressable
            key={t}
            accessibilityRole="tab"
            accessibilityState={{ selected: t === tab }}
            onPress={() => setTab(t)}
            style={[styles.tab, t === tab && styles.selected]}
          >
            <Text style={t === tab ? styles.selectedText : styles.tabText}>
              {t}
            </Text>
          </Pressable>
        ))}
      </View>
      <View style={styles.body}>
        {tab === 'Photo' ? <PhotoScreen /> : null}
        {tab === 'Camera' ? <CameraScreen /> : null}
        {tab === 'Self-test' ? <SelfTestScreen /> : null}
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    // SafeAreaView pads on iOS only; Android draws edge to edge under the status bar.
    paddingTop: Platform.OS === 'android' ? StatusBar.currentHeight : 0,
  },
  tabs: { flexDirection: 'row', padding: 8, gap: 8 },
  tab: {
    flex: 1,
    paddingVertical: 10,
    borderRadius: 8,
    alignItems: 'center',
    backgroundColor: '#eee',
  },
  selected: { backgroundColor: '#222' },
  tabText: { color: '#222' },
  selectedText: { color: '#fff', fontWeight: '600' },
  body: { flex: 1 },
});
