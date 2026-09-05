package model

type Action string

const (
	ActionRoute     Action = "route"
	ActionReject    Action = "reject"
	ActionHijackDNS Action = "hijack-dns"
)

type MatchExpr struct {
	Domain        []string
	DomainSuffix  []string
	DomainKeyword []string
	IPCIDR        []string
	RuleSet       []string
	ProcessName   []string
	Network       string
	Port          []string
}

type RuleOptions struct {
	NoResolve bool
}

// Rule is the unified rule AST. External and future import formats are
// converted into this before reaching the Router.
type Rule struct {
	Match   MatchExpr
	Action  Action
	Target  string
	Options RuleOptions
}
