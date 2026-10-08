package eventlog

import (
	"encoding/json"
	"strings"
)

var allowedContext = map[string]struct{}{"height": {}, "state": {}, "component": {}, "operation": {}, "code": {}}

func redact(raw json.RawMessage) ([]byte, error) {
	var event map[string]any
	if err := json.Unmarshal(raw, &event); err != nil {
		return nil, err
	}
	if context, ok := event["context"].(map[string]any); ok {
		for key, value := range context {
			if _, allowed := allowedContext[key]; !allowed || secretKey(key) || secretValue(value) {
				delete(context, key)
			}
		}
	}
	delete(event, "secret")
	return json.Marshal(event)
}

func secretKey(key string) bool {
	key = strings.ToLower(key)
	return strings.Contains(key, "token") || strings.Contains(key, "secret") || strings.Contains(key, "password") || strings.Contains(key, "mnemonic") || strings.Contains(key, "authorization")
}
func secretValue(value any) bool {
	text, ok := value.(string)
	if !ok {
		return false
	}
	text = strings.ToLower(text)
	return strings.Contains(text, "secret") || strings.Contains(text, "mnemonic") || strings.Contains(text, "password") || strings.Contains(text, "bearer ")
}
