package hooks

import (
	"encoding/json"
	"io"
	"time"
)

type hookHandler func(HookInput) ([]byte, int)

var (
	dispatchReadTimeout = 5 * time.Second
	hookHandlers        = map[string]hookHandler{}
)

func Dispatch(hookName string, stdin io.Reader, stdout io.Writer) int {
	inputBytes, ok := readAllWithTimeout(stdin, dispatchReadTimeout)
	if !ok || len(inputBytes) == 0 {
		return 0
	}

	var input HookInput
	if err := json.Unmarshal(inputBytes, &input); err != nil {
		return 0
	}

	handler, ok := hookHandlers[hookName]
	if !ok {
		return 0
	}

	output, exitCode := handler(input)
	if len(output) > 0 {
		_, _ = stdout.Write(output)
	}
	return exitCode
}

func readAllWithTimeout(r io.Reader, timeout time.Duration) ([]byte, bool) {
	type result struct {
		data []byte
		err  error
	}

	ch := make(chan result, 1)
	go func() {
		data, err := io.ReadAll(r)
		ch <- result{data: data, err: err}
	}()

	select {
	case res := <-ch:
		if res.err != nil {
			return nil, false
		}
		return res.data, true
	case <-time.After(timeout):
		return nil, false
	}
}
