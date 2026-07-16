// Package event provides bounded in-process fanout for live Starwatch events.
package event

import (
	"sync"
	"time"
)

type Message struct {
	Kind string    `json:"kind"`
	At   time.Time `json:"at"`
	Data any       `json:"data,omitempty"`
}

type Publisher interface {
	Publish(Message)
}

type Bus struct {
	mu          sync.Mutex
	nextID      uint64
	subscribers map[uint64]chan Message
}

func NewBus() *Bus {
	return &Bus{subscribers: make(map[uint64]chan Message)}
}

func (b *Bus) Subscribe(capacity int) (<-chan Message, func()) {
	if capacity < 1 {
		capacity = 1
	}
	b.mu.Lock()
	id := b.nextID
	b.nextID++
	channel := make(chan Message, capacity)
	b.subscribers[id] = channel
	b.mu.Unlock()
	var once sync.Once
	return channel, func() {
		once.Do(func() {
			b.mu.Lock()
			if current, ok := b.subscribers[id]; ok {
				delete(b.subscribers, id)
				close(current)
			}
			b.mu.Unlock()
		})
	}
}

func (b *Bus) Publish(message Message) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for id, subscriber := range b.subscribers {
		select {
		case subscriber <- message:
		default:
			delete(b.subscribers, id)
			close(subscriber)
		}
	}
}
