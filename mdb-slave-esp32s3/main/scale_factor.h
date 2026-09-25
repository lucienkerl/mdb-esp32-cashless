/*
 * scale_factor.h — currency <-> MDB scale-factor conversion
 *
 * MDB carries prices as integers in "scale factor units": the real amount is
 * value * scale_factor * 10^-decimal_places. At the scale factor 1 / 2
 * decimal places this project configures, a unit is simply a cent.
 *
 * Scale-factor units are integers by definition, but pow(10, -dec) is not
 * exactly representable — pow(10, -2) sits a hair above 0.01 — so the round
 * trip lands just *below* the integer it should hit: a credit of 8.20 comes
 * out of TO_SCALE_FACTOR as 819.9999999999999. Assigning that to the uint16
 * credit field truncates and silently eats a cent, and because the backend
 * scaled the same way before sending, the two truncations compounded: a card
 * balance of 8.20 reached the machine as 8.18.
 *
 * Hence llround() at the double -> integer step. TO_SCALE_FACTOR always
 * produces a whole number of units, so rounding is not a policy choice here,
 * it is what the unit means. FROM_SCALE_FACTOR stays a plain double: its
 * result is a currency amount, and callers print it.
 *
 * Regression test: mdb-slave-esp32s3/test/scale/run.sh
 */

#pragma once

#include <math.h>

#define TO_SCALE_FACTOR(p, scale_to, dec_to) \
	llround((double) (p) / (scale_to) / pow(10, -(dec_to)))

#define FROM_SCALE_FACTOR(p, scale_from, dec_from) \
	((double) (p) * (scale_from) * pow(10, -(dec_from)))
