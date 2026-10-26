#ifndef BUILDKIND_H
#define BUILDKIND_H

/**
 * @file buildkind.h
 * @brief Tells a development build from a release build (#508).
 *
 * mbt 3 builds one module and has no release switch of its own, so the only
 * thing that distinguishes the two is the version it stamps into
 * `<buildstamp.h>`: a development build reports "1.4.0-dev", a tagged release
 * "1.4.0". `/zosmf/test` is registered only when this says "development".
 *
 * A stop-gap: the endpoint's code stays in a release module, unreachable.
 * Leaving it out of the object needs mbt to hand the source a compile-time
 * release flag.
 */

/**
 * @return 1 if `version` ends in "-dev", 0 otherwise (NULL included, so an
 *         unknown version counts as a release and the endpoint stays off).
 */
int build_is_dev(const char *version)						asm("MFBLDDEV");

#endif /* BUILDKIND_H */
