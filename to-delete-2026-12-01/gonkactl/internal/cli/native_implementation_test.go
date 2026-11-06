package cli

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Inspect every implementation file, including optional build-tagged sources.
// Runtime validation separately rejects dynamically supplied interpreter paths.
func TestNativeImplementationHasNoEmbeddedScriptsOrInterpreterExec(t *testing.T) {
	for _, root := range []string{"../../cmd", ".."} {
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if err != nil {
				return err
			}
			ast.Inspect(file, func(node ast.Node) bool {
				if literal, ok := node.(*ast.BasicLit); ok && literal.Kind == token.STRING {
					value, _ := strconv.Unquote(literal.Value)
					if strings.HasPrefix(strings.TrimSpace(value), "#!") {
						t.Errorf("%s embeds an interpreted script", path)
					}
				}
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				selector, ok := call.Fun.(*ast.SelectorExpr)
				if !ok || selector.Sel.Name != "Command" && selector.Sel.Name != "CommandContext" {
					return true
				}
				index := 0
				if selector.Sel.Name == "CommandContext" {
					index = 1
				}
				if len(call.Args) <= index {
					return true
				}
				literal, ok := call.Args[index].(*ast.BasicLit)
				if !ok || literal.Kind != token.STRING {
					return true
				}
				value, _ := strconv.Unquote(literal.Value)
				base := filepath.Base(value)
				if base == "sh" || base == "bash" || strings.HasPrefix(base, "python") ||
					strings.HasSuffix(base, ".sh") || strings.HasSuffix(base, ".py") {
					t.Errorf("%s executes an interpreter or script: %s", path, value)
				}
				return true
			})
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}
