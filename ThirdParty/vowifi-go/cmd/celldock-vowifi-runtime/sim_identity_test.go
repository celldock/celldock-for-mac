package main

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/boa-z/vowifi-go/runtimehost/identity"
	"github.com/boa-z/vowifi-go/runtimehost/simtransport"
)

type simIdentityAT struct {
	calls    []string
	response string
	err      error
}

func (a *simIdentityAT) ExecuteATSilent(cmd string, _ time.Duration) (string, error) {
	a.calls = append(a.calls, cmd)
	return a.response, a.err
}

func TestReadSIMProfileUsesADForEPDGAndIMSIdentity(t *testing.T) {
	// Synthetic IMSI: with a two-digit MNC the first subscriber digit is 6.
	const imsi = "262036000000001"
	const imei = "490154203237518"
	for _, tt := range []struct {
		name, ad, mnc, paddedMNC string
	}{
		{"two-digit MNC", "01000102", "03", "003"},
		{"three-digit MNC", "01000103", "036", "036"},
		{"RFU high nibble", "010001F2", "03", "003"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			at := &simIdentityAT{response: `+CRSM: 144,0,"` + tt.ad + `"` + "\r\nOK\r\n"}
			profile, err := readSIMProfile(simtransport.NewAdapter(at), imsi, imei)
			if err != nil {
				t.Fatal(err)
			}
			if profile != (identity.Profile{IMSI: imsi, IMEI: imei, MCC: "262", MNC: tt.mnc}) {
				t.Fatalf("profile = %+v", profile)
			}
			if !reflect.DeepEqual(at.calls, []string{"AT+CRSM=176,28589,0,0,4"}) {
				t.Fatalf("AT calls = %v", at.calls)
			}
			prepared, err := identity.PrepareStart(identity.PrepareStartInput{Profile: profile})
			if err != nil {
				t.Fatal(err)
			}
			if want := "epdg.epc.mnc" + tt.paddedMNC + ".mcc262.pub.3gppnetwork.org"; prepared.EPDGAddr != want {
				t.Fatalf("ePDG = %q, want %q", prepared.EPDGAddr, want)
			}
			realm := "ims.mnc" + tt.paddedMNC + ".mcc262.3gppnetwork.org"
			if prepared.IMSIdentity.Domain != realm || prepared.IMSIdentity.IMPI != imsi+"@"+realm ||
				prepared.IMSIdentity.IMPU != "sip:"+imsi+"@"+realm {
				t.Fatalf("IMS identity = %+v, want realm %q", prepared.IMSIdentity, realm)
			}
			naiRealm := "nai.epc.mnc" + tt.paddedMNC + ".mcc262.3gppnetwork.org"
			if prepared.CarrierPolicy.IMS.NAIRealm != naiRealm ||
				!strings.HasSuffix(prepared.CarrierPolicy.IMS.PermanentNAI, "@"+naiRealm) {
				t.Fatalf("NAI = %q, want realm %q", prepared.CarrierPolicy.IMS.PermanentNAI, naiRealm)
			}
		})
	}
}

func TestReadSIMProfilePreservesFallbackWhenADIsUnavailable(t *testing.T) {
	const imsi = "262036000000001"
	for _, tt := range []struct {
		name, response, wantError string
		err                       error
	}{
		{name: "transport error", err: errors.New("bridge unavailable"), wantError: "read EF_AD"},
		{name: "unsupported AT command", response: "ERROR", wantError: "read EF_AD"},
		{name: "missing file", response: `+CRSM: 106,130,""`, wantError: "SW=6A82"},
		{name: "short EF", response: `+CRSM: 144,0,"010001"`, wantError: "no valid MNC length"},
		{name: "invalid length", response: `+CRSM: 144,0,"01000104"`, wantError: "no valid MNC length"},
		{name: "unset length", response: `+CRSM: 144,0,"010001FF"`, wantError: "no valid MNC length"},
		{name: "malformed data", response: `+CRSM: 144,0,"XYZ"`, wantError: "read EF_AD"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			at := &simIdentityAT{response: tt.response, err: tt.err}
			profile, err := readSIMProfile(simtransport.NewAdapter(at), imsi, "")
			if err == nil || !strings.Contains(err.Error(), tt.wantError) {
				t.Fatalf("error = %v, want %q", err, tt.wantError)
			}
			if profile != (identity.Profile{IMSI: imsi}) {
				t.Fatalf("fallback profile = %+v", profile)
			}
		})
	}
}

func TestReadSIMProfileRejectsShortIMSIWithoutSlicing(t *testing.T) {
	at := &simIdentityAT{response: `+CRSM: 144,0,"01000103"`}
	profile, err := readSIMProfile(simtransport.NewAdapter(at), "26203", "")
	if err == nil || profile.MCC != "" || profile.MNC != "" {
		t.Fatalf("profile = %+v, error = %v", profile, err)
	}
}
