---
'react-native-shared-hero': patch
---

Skip pairing a newly registered iOS hero with a twin whose deferred unregister opted out of return flights (`returnFlightEnabled={false}`), preventing bogus mid-scroll flights during horizontal pager handovers (#13).
