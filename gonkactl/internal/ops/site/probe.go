package site

func ProbeExpected(status int, body []byte) bool { return status == 200 && len(body) > 0 }
