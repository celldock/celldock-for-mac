package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/boa-z/vowifi-go/engine/sim"
	"github.com/boa-z/vowifi-go/engine/swu"
	"github.com/boa-z/vowifi-go/engine/swu/ikev2"
	"github.com/boa-z/vowifi-go/runtimehost"
	"github.com/boa-z/vowifi-go/runtimehost/identity"
	"github.com/boa-z/vowifi-go/runtimehost/simauth"
	"github.com/boa-z/vowifi-go/runtimehost/simtransport"
	"github.com/boa-z/vowifi-go/runtimehost/voiceclient"
)

const controlProtocolVersion = 4

type config struct {
	SessionID      string `json:"session_id"`
	SIMBridgeHost  string `json:"sim_bridge_host"`
	SIMBridgeToken string `json:"sim_bridge_token"`
	OuterInterface string `json:"outer_interface"`
	OuterGateway   string `json:"outer_gateway"`
	OuterLocalIP   string `json:"outer_local_ip"`
	ProxyURL       string `json:"proxy_url,omitempty"`
	StatusPath     string `json:"status_path"`
	TUNMTU         int    `json:"tun_mtu,omitempty"`
}

type status struct {
	Protocol       int    `json:"protocol"`
	Supported      bool   `json:"supported"`
	Running        bool   `json:"running"`
	SessionID      string `json:"session"`
	Phase          string `json:"phase"`
	DataplaneMode  string `json:"dataplane_mode"`
	SIMReady       bool   `json:"sim_ready"`
	AccessReady    bool   `json:"access_ready"`
	TunnelReady    bool   `json:"tunnel_ready"`
	IMSReady       bool   `json:"ims_ready"`
	RegStatus      int    `json:"reg_status"`
	LastErrorClass string `json:"last_error_class,omitempty"`
	LastReason     string `json:"last_reason,omitempty"`
	UpdatedAt      string `json:"updated_at"`
}

type statusStore struct {
	mu   sync.Mutex
	path string
	s    status
}

func main() {
	if len(os.Args) != 3 || os.Args[1] != "run" {
		fmt.Fprintln(os.Stderr, "usage: celldock-vowifi-runtime run CONFIG_PATH")
		os.Exit(64)
	}
	raw, err := os.ReadFile(os.Args[2])
	if err != nil {
		fatal(err)
	}
	var cfg config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		fatal(fmt.Errorf("decode config: %w", err))
	}
	if err := cfg.validate(); err != nil {
		fatal(err)
	}
	if err := run(cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(cfg config) error {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	store := &statusStore{path: cfg.StatusPath, s: status{
		Protocol:      controlProtocolVersion,
		Supported:     true,
		Running:       true,
		SessionID:     cfg.SessionID,
		Phase:         "starting",
		DataplaneMode: swu.DataplaneModeUserspace,
	}}
	if err := store.write(); err != nil {
		return err
	}
	defer store.update(func(s *status) {
		s.Running = false
		if s.Phase != "error" {
			s.Phase = "stopped"
		}
	})

	at := &remoteAT{host: cfg.SIMBridgeHost, token: cfg.SIMBridgeToken}
	transport := simtransport.NewAdapter(at)
	imsi, err := transport.ReadIMSI()
	if err != nil {
		return store.fail("sim", fmt.Errorf("read IMSI: %w", err))
	}
	imei, err := transport.ReadIMEI()
	if err != nil {
		return store.fail("sim", fmt.Errorf("read IMEI: %w", err))
	}
	profile, err := readSIMProfile(transport, imsi, imei)
	if err != nil {
		// Some modems/cards do not expose EF_AD through CRSM. Preserve the
		// existing fallback in that case, but make the missing evidence visible.
		fmt.Fprintf(os.Stderr, "SIM MNC length unavailable: %v; using IMSI-derived PLMN\n", err)
	}
	aka := simauth.NewAKAProvider(transport)
	simAdapter := runtimehost.NewReaderSIMAdapter(&simWithIMSI{AKAProvider: aka, imsi: imsi})
	defer simAdapter.Close()
	modem := &remoteModem{Adapter: transport, deviceID: cfg.OuterInterface}
	access := runtimehost.NewModemAccessAdapter(modem)
	prepared, err := identity.PrepareStart(identity.PrepareStartInput{
		DeviceID: cfg.OuterInterface + "-imei-" + imei,
		Profile:  profile,
		Access:   access,
	})
	if err != nil {
		return store.fail("identity", fmt.Errorf("prepare carrier identity: %w", err))
	}
	store.update(func(s *status) {
		s.Phase = "sim_ready"
		s.SIMReady = true
		s.AccessReady = true
		s.RegStatus = 1
		s.LastReason = "SIM identity prepared"
	})

	outerRoutes := &outerRouteSet{iface: cfg.OuterInterface, gateway: cfg.OuterGateway}
	proxy, err := runtimeProxy(cfg.ProxyURL)
	if err != nil {
		return store.fail("proxy", err)
	}
	defer outerRoutes.cleanup(context.Background())
	epdgCandidates := []string{prepared.EPDGAddr}
	if proxy != nil {
		if parsed, parseErr := url.Parse(proxy.URL); parseErr == nil {
			if err := outerRoutes.protectHost(ctx, parsed.Hostname()); err != nil {
				return store.fail("routing", fmt.Errorf("protect proxy route: %w", err))
			}
		}
	} else {
		addresses, resolveErr := resolveOuterHost(ctx, prepared.EPDGAddr)
		if resolveErr != nil {
			return store.fail("routing", fmt.Errorf("resolve ePDG: %w", resolveErr))
		}
		if err := outerRoutes.protectAddresses(ctx, addresses); err != nil {
			return store.fail("routing", fmt.Errorf("protect ePDG route: %w", err))
		}
		epdgCandidates = repeatDirectEPDGCandidates(directEPDGCandidates(addresses, 6), 2)
		if len(epdgCandidates) == 0 {
			return store.fail("routing", errors.New("resolve ePDG: no usable IP addresses"))
		}
	}

	routing := &swu.DarwinTUNRoutingManager{}
	tunnelManager := swu.NewTUNIKETunnelManager(
		swu.IKEPacketTunnelManagerConfig{
			SIM:     simAdapter,
			SA:      ikev2.EPDGCompatibleIKEProposal(),
			ChildSA: ikev2.EPDGCompatibleESPProposal(nil),
		},
		swu.TUNTunnelManagerConfig{
			RoutingManager:    routing,
			DefaultRoutes:     false,
			ProtectEPDGRoutes: false,
			MTU:               normalizedMTU(cfg.TUNMTU),
			RoutingConfigFactory: func(_ swu.TunnelConfig, result swu.TunnelResult, iface string) (swu.TUNRoutingConfig, error) {
				routes := make([]swu.TUNRoute, 0, len(result.DNSServers)+len(result.PCSCFServers))
				for _, server := range append(append([]string(nil), result.DNSServers...), result.PCSCFServers...) {
					if host := strings.Trim(strings.TrimSpace(server), "[]"); net.ParseIP(host) != nil {
						routes = append(routes, swu.TUNRoute{Destination: host})
					}
				}
				return swu.TUNRoutingConfig{
					InterfaceName: iface,
					MTU:           normalizedMTU(cfg.TUNMTU),
					Addresses:     nonemptyStrings(result.LocalInnerIP),
					Routes:        routes,
				}, nil
			},
		},
	)
	registrar := &darwinIMSRegistrar{routing: routing}
	store.update(func(s *status) {
		s.Phase = "starting"
		s.LastReason = "establishing SWu tunnel"
	})
	var instance *runtimehost.Instance
	var startErr error
	for index, candidate := range epdgCandidates {
		attemptPrepared := prepared
		attemptPrepared.EPDGAddr = candidate
		instance, startErr = runtimehost.Start(ctx, runtimehost.StartRequest{
			Mode:        runtimehost.StartModeMain,
			DeviceID:    cfg.OuterInterface + "-imei-" + imei,
			TraceID:     runtimehost.NewTraceID(),
			Profile:     attemptPrepared.Profile,
			Prepared:    &attemptPrepared,
			NetworkMode: "IWLAN",
			SIM:         simAdapter,
			Access:      access,
			Dataplane: runtimehost.DataplanePolicy{
				Mode:   swu.DataplaneModeUserspace,
				TUNMTU: normalizedMTU(cfg.TUNMTU),
			},
			Proxy:         proxy,
			TunnelManager: tunnelManager,
			IMSRegistrar:  registrar,
		})
		if startErr == nil {
			break
		}
		if proxy != nil || index+1 >= len(epdgCandidates) || !isRetryableDirectEPDGError(startErr) {
			break
		}
		store.update(func(s *status) {
			s.Phase = "starting"
			s.LastReason = fmt.Sprintf("ePDG did not respond; trying candidate %d of %d", index+2, len(epdgCandidates))
		})
	}
	err = startErr
	if err != nil {
		return store.fail(classifyStartError(err), err)
	}
	defer instance.Stop(context.Background())
	diagnostic := instance.DiagnosticState()
	store.update(func(s *status) {
		s.Phase = "ready"
		s.SIMReady = diagnostic.SIMReady
		s.AccessReady = diagnostic.AccessReady
		s.TunnelReady = diagnostic.TunnelReady
		s.IMSReady = diagnostic.IMSReady
		s.RegStatus = diagnostic.RegStatus
		s.LastReason = diagnostic.LastReason
	})
	<-ctx.Done()
	return nil
}

type remoteAT struct {
	host  string
	token string
}

type bridgeRequest struct {
	Token     string `json:"token"`
	Command   string `json:"command"`
	TimeoutMS int    `json:"timeout_ms"`
}

type bridgeResponse struct {
	OK     bool   `json:"ok"`
	Output string `json:"output"`
	Error  string `json:"error,omitempty"`
}

func (r *remoteAT) ExecuteATSilent(command string, timeout time.Duration) (string, error) {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	conn, err := net.DialTimeout("tcp", r.host, minDuration(timeout, 5*time.Second))
	if err != nil {
		return "", fmt.Errorf("connect SIM bridge: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout + 2*time.Second))
	if err := json.NewEncoder(conn).Encode(bridgeRequest{Token: r.token, Command: command, TimeoutMS: int(timeout / time.Millisecond)}); err != nil {
		return "", err
	}
	var response bridgeResponse
	if err := json.NewDecoder(bufio.NewReader(conn)).Decode(&response); err != nil {
		return "", fmt.Errorf("decode SIM bridge response: %w", err)
	}
	if !response.OK {
		return response.Output, errors.New(firstNonempty(response.Error, "SIM bridge rejected command"))
	}
	return response.Output, nil
}

type simWithIMSI struct {
	*simauth.AKAProvider
	imsi string
}

func (s *simWithIMSI) GetIMSI() (string, error) { return s.imsi, nil }

type remoteModem struct {
	*simtransport.Adapter
	deviceID string
}

func (m *remoteModem) DeviceID() string                { return m.deviceID }
func (m *remoteModem) IsHealthy() bool                 { return true }
func (m *remoteModem) IsSimInserted() bool             { return true }
func (m *remoteModem) QuerySIMInserted() (bool, error) { return true, nil }
func (m *remoteModem) GetRegStatus() (int, string)     { return 1, "SIM ready for IWLAN" }
func (m *remoteModem) GetNetworkMode() string          { return "IWLAN" }
func (m *remoteModem) Stop()                           {}
func (m *remoteModem) GetISIMIdentity() (identity.Identity, error) {
	return identity.ReadISIMIdentity(m.Adapter)
}

type darwinIMSRegistrar struct {
	routing *swu.DarwinTUNRoutingManager
}

func (r *darwinIMSRegistrar) RegisterIMS(ctx context.Context, cfg runtimehost.IMSRegistrationConfig) (runtimehost.IMSRegistrationResult, error) {
	base := voiceclient.NetSIPResolver{DNSServers: cfg.Tunnel.DNSServers, Timeout: 12 * time.Second}
	resolver := &routeAddingResolver{base: base, routing: r.routing, pcscf: append([]string(nil), cfg.Tunnel.PCSCFServers...)}
	return (runtimehost.WireIMSRegistrar{Resolver: resolver, Timeout: 12 * time.Second}).RegisterIMS(ctx, cfg)
}

type routeAddingResolver struct {
	base    voiceclient.NetSIPResolver
	routing *swu.DarwinTUNRoutingManager
	pcscf   []string
}

func (r *routeAddingResolver) ResolveSIPServer(ctx context.Context, network, uri string) (string, error) {
	targets, err := r.ResolveSIPServers(ctx, network, uri)
	if err != nil {
		return "", err
	}
	if len(targets) == 0 {
		return "", errors.New("SIP resolver returned no targets")
	}
	return targets[0], nil
}

func (r *routeAddingResolver) ResolveSIPServers(ctx context.Context, network, uri string) ([]string, error) {
	var targets []string
	for _, raw := range r.pcscf {
		if ip := net.ParseIP(strings.Trim(strings.TrimSpace(raw), "[]")); ip != nil {
			targets = append(targets, net.JoinHostPort(ip.String(), "5060"))
		}
	}
	if len(targets) == 0 {
		var err error
		targets, err = r.base.ResolveSIPServers(ctx, network, uri)
		if err != nil {
			return nil, err
		}
	}
	iface := r.routing.ActiveInterfaceName()
	for _, target := range targets {
		host, _, splitErr := net.SplitHostPort(target)
		if splitErr != nil {
			host = strings.Trim(target, "[]")
		}
		if ip := net.ParseIP(strings.Trim(host, "[]")); ip != nil {
			if err := r.routing.AddHostRoute(ctx, iface, ip.String()); err != nil {
				return nil, err
			}
		}
	}
	return targets, nil
}

type outerRouteSet struct {
	iface   string
	gateway string
	mu      sync.Mutex
	undo    [][]string
}

func (r *outerRouteSet) protectHost(ctx context.Context, host string) error {
	host = strings.TrimSpace(host)
	if host == "" || strings.TrimSpace(r.gateway) == "" {
		return nil
	}
	addresses, err := resolveOuterHost(ctx, host)
	if err != nil {
		return err
	}
	return r.protectAddresses(ctx, addresses)
}

func (r *outerRouteSet) protectAddresses(ctx context.Context, addresses []net.IPAddr) error {
	if strings.TrimSpace(r.gateway) == "" {
		return nil
	}
	for _, item := range addresses {
		ip := item.IP
		if !shouldProtectOuterIP(ip) {
			continue
		}
		family := "-inet"
		if ip.To4() == nil {
			family = "-inet6"
		}
		args := []string{"-n", "add", family, "-host", ip.String(), r.gateway}
		out, commandErr := exec.CommandContext(ctx, "/sbin/route", args...).CombinedOutput()
		if commandErr != nil && !strings.Contains(strings.ToLower(string(out)), "file exists") {
			return fmt.Errorf("route %s through %s: %v: %s", ip, r.iface, commandErr, strings.TrimSpace(string(out)))
		}
		r.mu.Lock()
		r.undo = append(r.undo, []string{"-n", "delete", family, "-host", ip.String(), r.gateway})
		r.mu.Unlock()
	}
	return nil
}

func shouldProtectOuterIP(ip net.IP) bool {
	return ip != nil && !ip.IsLoopback() && !ip.IsUnspecified()
}

func directEPDGCandidates(addresses []net.IPAddr, limit int) []string {
	if limit <= 0 {
		return nil
	}
	seen := make(map[string]bool)
	var out []string
	for _, familyIPv4 := range []bool{true, false} {
		for _, address := range addresses {
			ip := address.IP
			if ip == nil || (ip.To4() != nil) != familyIPv4 {
				continue
			}
			value := ip.String()
			if seen[value] {
				continue
			}
			seen[value] = true
			out = append(out, value)
			if len(out) == limit {
				return out
			}
		}
	}
	return out
}

// repeatDirectEPDGCandidates retries the complete address set in rounds.
// Mobile ePDG anycast nodes occasionally drop the first NAT-T exchange, and
// DNS may expose only one address, so address-only failover is insufficient.
func repeatDirectEPDGCandidates(candidates []string, rounds int) []string {
	if rounds <= 0 || len(candidates) == 0 {
		return nil
	}
	out := make([]string, 0, len(candidates)*rounds)
	for round := 0; round < rounds; round++ {
		out = append(out, candidates...)
	}
	return out
}

func isRetryableDirectEPDGError(err error) bool {
	if err == nil {
		return false
	}
	value := strings.ToLower(err.Error())
	return strings.Contains(value, "swu tunnel establishment failed") && (strings.Contains(value, "timeout") ||
		strings.Contains(value, "timed out") ||
		strings.Contains(value, "network is unreachable") ||
		strings.Contains(value, "no route to host") ||
		strings.Contains(value, "connection refused"))
}

func resolveOuterHost(ctx context.Context, host string) ([]net.IPAddr, error) {
	host = strings.Trim(strings.TrimSpace(host), "[]")
	if host == "" {
		return nil, errors.New("host is empty")
	}
	if ip := net.ParseIP(host); ip != nil {
		return []net.IPAddr{{IP: ip}}, nil
	}

	type resolverAttempt struct {
		name     string
		resolver *net.Resolver
	}
	attempts := []resolverAttempt{{name: "system", resolver: net.DefaultResolver}}
	for _, server := range []string{"1.1.1.1:53", "8.8.8.8:53", "1.1.1.1:53", "8.8.8.8:53"} {
		server := server
		attempts = append(attempts, resolverAttempt{
			name: server,
			resolver: &net.Resolver{
				PreferGo: true,
				Dial: func(resolveCtx context.Context, _, _ string) (net.Conn, error) {
					return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(resolveCtx, "udp", server)
				},
			},
		})
	}

	var failures []string
	var addresses []net.IPAddr
	seen := make(map[string]bool)
	for _, attempt := range attempts {
		lookupCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		resolved, err := attempt.resolver.LookupIPAddr(lookupCtx, host)
		cancel()
		if err == nil && len(resolved) > 0 {
			for _, address := range resolved {
				value := address.IP.String()
				if value == "<nil>" || seen[value] {
					continue
				}
				seen[value] = true
				addresses = append(addresses, address)
			}
			continue
		}
		if err == nil {
			err = errors.New("no addresses returned")
		}
		failures = append(failures, attempt.name+": "+err.Error())
	}
	if len(addresses) > 0 {
		return addresses, nil
	}
	return nil, fmt.Errorf("lookup %s failed (%s)", host, strings.Join(failures, "; "))
}

func (r *outerRouteSet) cleanup(ctx context.Context) {
	r.mu.Lock()
	undo := append([][]string(nil), r.undo...)
	r.undo = nil
	r.mu.Unlock()
	for i := len(undo) - 1; i >= 0; i-- {
		_ = exec.CommandContext(ctx, "/sbin/route", undo[i]...).Run()
	}
}

func runtimeProxy(raw string) (*runtimehost.ProxyConfig, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	parsed, err := url.Parse(raw)
	if err != nil || !strings.EqualFold(parsed.Scheme, "socks5") || parsed.Hostname() == "" || parsed.Port() == "" {
		return nil, fmt.Errorf("invalid SOCKS5 proxy URL")
	}
	proxy := &runtimehost.ProxyConfig{ID: "celldock", URL: raw, Address: parsed.Host, Enabled: true}
	if parsed.User != nil {
		proxy.Username = parsed.User.Username()
		proxy.Password, _ = parsed.User.Password()
	}
	return proxy, nil
}

func (c config) validate() error {
	if strings.TrimSpace(c.SessionID) == "" || strings.TrimSpace(c.SIMBridgeToken) == "" {
		return errors.New("session and SIM bridge token are required")
	}
	if _, _, err := net.SplitHostPort(c.SIMBridgeHost); err != nil {
		return fmt.Errorf("invalid SIM bridge host: %w", err)
	}
	if !strings.HasPrefix(strings.TrimSpace(c.OuterInterface), "en") && !strings.HasPrefix(strings.TrimSpace(c.OuterInterface), "bridge") {
		return errors.New("outer interface is not an allowed Mac network interface")
	}
	if c.OuterGateway != "" && net.ParseIP(c.OuterGateway) == nil {
		return errors.New("outer gateway is invalid")
	}
	if strings.TrimSpace(c.StatusPath) == "" || !filepath.IsAbs(c.StatusPath) {
		return errors.New("absolute status path is required")
	}
	return nil
}

func (s *statusStore) update(change func(*status)) {
	s.mu.Lock()
	change(&s.s)
	_ = s.writeLocked()
	s.mu.Unlock()
}

func (s *statusStore) fail(class string, err error) error {
	s.update(func(current *status) {
		current.Phase = "error"
		current.LastErrorClass = class
		current.LastReason = runtimehost.SafeDiagnosticError(err)
	})
	return err
}

func (s *statusStore) write() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.writeLocked()
}

func (s *statusStore) writeLocked() error {
	s.s.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	data, err := json.Marshal(s.s)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	temporary := s.path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, s.path)
}

func classifyStartError(err error) string {
	value := strings.ToLower(err.Error())
	switch {
	case strings.Contains(value, "ike") || strings.Contains(value, "epdg") || strings.Contains(value, "tunnel"):
		return "tunnel"
	case strings.Contains(value, "ims") || strings.Contains(value, "sip") || strings.Contains(value, "register"):
		return "ims"
	case strings.Contains(value, "aka") || strings.Contains(value, "sim") || strings.Contains(value, "apdu"):
		return "sim"
	default:
		return "runtime"
	}
}

func normalizedMTU(value int) int {
	if value >= 1200 && value <= 1500 {
		return value
	}
	return 1280
}

func nonemptyStrings(values ...string) []string {
	var out []string
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			out = append(out, value)
		}
	}
	return out
}

func firstNonempty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

var _ sim.AKAProvider = (*simWithIMSI)(nil)
