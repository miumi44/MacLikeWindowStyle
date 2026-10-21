import Foundation

@main struct FeaturePreferencesTests {
    static func main() {
        let suite="WindowBridgeTests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }

        let preference=WindowFeaturePreference.switcher
        assert(!preference.enabled(in:defaults),"unset window features must default off")
        preference.persist(true,started:false,userInitiated:true,defaults:defaults)
        assert(!preference.enabled(in:defaults),"a failed start must not save the feature as enabled")
        preference.persist(true,started:true,userInitiated:true,defaults:defaults)
        assert(preference.enabled(in:defaults),"a successful user enable must persist")
        preference.persist(false,started:false,userInitiated:false,defaults:defaults)
        assert(preference.enabled(in:defaults),"startup failure must preserve the saved desired state")
        preference.persist(false,started:true,userInitiated:true,defaults:defaults)
        assert(!preference.enabled(in:defaults),"an explicit user disable must persist")

        let management=WindowFeaturePreference.windowManagement
        management.persist(true,started:true,userInitiated:true,defaults:defaults)
        let reloaded=UserDefaults(suiteName:suite)!
        assert(management.enabled(in:reloaded),"window management preference must restore independently")
        assert(!preference.enabled(in:reloaded),"saving window management must not re-enable the switcher")

        print("PASS: defaults, successful enable, failed-start preservation, startup preservation, explicit disable, and independent restoration")
    }
}
