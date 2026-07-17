// lsan_off.cc — fleet-standard build-time LeakSanitizer switch (SPEC §6.2 item 15).
//
// -fsanitize=address always bundles LeakSanitizer. Leaks are not the defect class this target is
// fuzzed for (ASan memory-safety checks and halting UBSan are), so LSan is turned off at BUILD time
// by linking this hook into the sanitized `mac` binary. ASan and UBSan stay fully active; no runtime
// sanitizer options are set anywhere.
extern "C" int __lsan_is_turned_off() { return 1; }
