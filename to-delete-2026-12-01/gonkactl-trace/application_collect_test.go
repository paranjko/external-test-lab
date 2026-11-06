package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestApplicationCollection(t *testing.T) {
	for _, mode := range []string{"pages", "missing-height", "wrong-height", "pruned", "repeat", "missing-pagination", "redirect", "oversized"} {
		t.Run(mode, func(t *testing.T) {
			calls := 0
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Header.Get("x-cosmos-block-height") != "306550" {
					t.Error("historical height not sent")
				}
				if mode != "missing-height" {
					w.Header().Set("x-cosmos-block-height", "306550")
				}
				if mode == "wrong-height" {
					w.Header().Set("x-cosmos-block-height", "999999")
				}
				if mode == "pruned" {
					http.Error(w, "pruned", 500)
					return
				}
				if mode == "redirect" {
					w.Header().Set("Location", "/elsewhere")
					w.WriteHeader(302)
					return
				}
				if mode == "oversized" {
					w.Write(make([]byte, maxSourceBytes+1))
					return
				}
				if mode == "missing-pagination" {
					fmt.Fprint(w, `{}`)
					return
				}
				if calls == 1 || mode == "repeat" {
					fmt.Fprint(w, `{"members":[],"pagination":{"next_key":"ab+/="}}`)
					return
				}
				if r.URL.Query().Get("pagination.key") != "ab+/=" {
					t.Error("cursor changed")
				}
				fmt.Fprint(w, `{"members":[],"pagination":{"next_key":null}}`)
			}))
			defer s.Close()
			x := collector{dir: t.TempDir(), client: s.Client()}
			x.application(Node{ID: "node0", REST: s.URL}, ApplicationRequest{Height: 306550, Path: "/cosmos/group/v1/group_members/7", Paginated: true}, 0)
			last := x.d.Receipts[len(x.d.Receipts)-1]
			if mode == "pages" {
				if calls != 2 || last.Error != "" || !last.Application.Complete {
					t.Fatalf("incomplete: %+v", last)
				}
			} else if last.Error == "" || last.Application.Complete {
				t.Fatalf("gap hidden: %+v", last)
			}
			if calls > 2 {
				t.Fatal("unexpected requests")
			}
		})
	}
}

func TestApplicationSelection(t *testing.T) {
	c := Config{Nodes: []Node{{ID: "node0", REST: "http://localhost:1317"}}, ApplicationRequests: []ApplicationRequest{{Node: "node0", Height: 10, Path: "/productscience/inference/inference/current_epoch_group_data"}}}
	if err := validateApplication(c, 10, 11); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"/admin", "//evil/params", "/cosmos/staking/v1beta1/validators?height=0", "/../params"} {
		c.ApplicationRequests[0].Path = p
		if validateApplication(c, 10, 11) == nil {
			t.Fatalf("accepted %s", p)
		}
	}
}
