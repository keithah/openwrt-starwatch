package event

import (
	"testing"
	"time"
)

func TestBusDisconnectsSubscriberOnOverflow(t *testing.T) {
	bus := NewBus()
	messages, cancel := bus.Subscribe(1)
	defer cancel()
	bus.Publish(Message{Kind: "one", At: time.Unix(1, 0)})
	bus.Publish(Message{Kind: "two", At: time.Unix(2, 0)})

	if _, ok := <-messages; !ok {
		t.Fatal("buffered message was not delivered")
	}
	if _, ok := <-messages; ok {
		t.Fatal("overflowed subscriber was not disconnected")
	}
}

func TestBusCancelIsIdempotent(t *testing.T) {
	bus := NewBus()
	messages, cancel := bus.Subscribe(1)
	cancel()
	cancel()
	if _, ok := <-messages; ok {
		t.Fatal("canceled subscription remained open")
	}
}
