package main

import (
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/boa-z/vowifi-go/runtimehost/identity"
	"github.com/boa-z/vowifi-go/runtimehost/simauth"
	"github.com/boa-z/vowifi-go/runtimehost/simtransport"
)

// readSIMProfile uses the home SIM's EF_AD, not the serving network, to split
// the already-read IMSI. Its total length cannot distinguish a two-digit MNC
// from a three-digit MNC. On error, the returned profile retains the previous
// IMSI-only fallback so cards without accessible EF_AD keep their old behavior.
func readSIMProfile(transport *simtransport.Adapter, imsi, imei string) (identity.Profile, error) {
	profile := identity.Profile{IMSI: imsi, IMEI: imei}
	// 3GPP TS 31.102: EF_AD (6FAD), byte 4, low nibble is the MNC length.
	ad, err := transport.ReadCRSMBinary(0x6FAD, 0, 4, "")
	if err != nil {
		return profile, fmt.Errorf("read EF_AD: %w", err)
	}
	if !ad.Success() {
		return profile, fmt.Errorf("read EF_AD: SW=%s", ad.StatusString())
	}
	data, err := hex.DecodeString(ad.Data)
	if err != nil {
		return profile, fmt.Errorf("decode EF_AD: %w", err)
	}
	mncLength, ok := simauth.MNCLengthFromAD(data)
	if !ok {
		return profile, errors.New("EF_AD has no valid MNC length")
	}
	if len(imsi) < 3+mncLength {
		return profile, errors.New("IMSI is shorter than the SIM's PLMN")
	}
	profile.MCC = imsi[:3]
	profile.MNC = imsi[3 : 3+mncLength]
	return profile, nil
}
