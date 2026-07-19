package api

import (
	"encoding"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strings"
)

var (
	jsonMarshalerType = reflect.TypeOf((*json.Marshaler)(nil)).Elem()
	textMarshalerType = reflect.TypeOf((*encoding.TextMarshaler)(nil)).Elem()
)

// jsonSafeClone produces the same JSON-facing shape as value while replacing
// float values that encoding/json cannot represent. Pointer floats can become
// JSON null; scalar floats retain their field and become zero.
func jsonSafeClone(value any) any {
	return jsonSafeValue(reflect.ValueOf(value))
}

func jsonSafeValue(value reflect.Value) any {
	if !value.IsValid() {
		return nil
	}
	if value.CanInterface() && (value.Type().Implements(jsonMarshalerType) || value.Type().Implements(textMarshalerType)) {
		return value.Interface()
	}
	switch value.Kind() {
	case reflect.Interface:
		if value.IsNil() {
			return nil
		}
		return jsonSafeValue(value.Elem())
	case reflect.Pointer:
		if value.IsNil() {
			return nil
		}
		if isFloat(value.Elem()) && !finiteFloat(value.Elem()) {
			return nil
		}
		return jsonSafeValue(value.Elem())
	case reflect.Struct:
		result := make(map[string]any)
		typ := value.Type()
		for index := 0; index < value.NumField(); index++ {
			fieldType := typ.Field(index)
			if fieldType.PkgPath != "" {
				continue
			}
			name, options, _ := strings.Cut(fieldType.Tag.Get("json"), ",")
			if name == "-" {
				continue
			}
			field := value.Field(index)
			if strings.Contains(","+options+",", ",omitempty,") && jsonEmpty(field) {
				continue
			}
			if fieldType.Anonymous && name == "" {
				if embedded, ok := jsonSafeValue(field).(map[string]any); ok {
					for key, item := range embedded {
						result[key] = item
					}
					continue
				}
			}
			if name == "" {
				name = fieldType.Name
			}
			result[name] = jsonSafeValue(field)
		}
		return result
	case reflect.Map:
		if value.IsNil() {
			return nil
		}
		result := make(map[string]any, value.Len())
		iterator := value.MapRange()
		for iterator.Next() {
			key := iterator.Key()
			name := fmt.Sprint(key.Interface())
			if key.Kind() == reflect.String {
				name = key.String()
			}
			result[name] = jsonSafeValue(iterator.Value())
		}
		return result
	case reflect.Slice:
		if value.IsNil() {
			return nil
		}
		if value.Type().Elem().Kind() == reflect.Uint8 && value.CanInterface() {
			return value.Interface()
		}
		fallthrough
	case reflect.Array:
		result := make([]any, value.Len())
		for index := 0; index < value.Len(); index++ {
			result[index] = jsonSafeValue(value.Index(index))
		}
		return result
	case reflect.Float32, reflect.Float64:
		if !finiteFloat(value) {
			return reflect.Zero(value.Type()).Interface()
		}
		return value.Interface()
	default:
		if value.CanInterface() {
			return value.Interface()
		}
		return nil
	}
}

func isFloat(value reflect.Value) bool {
	return value.Kind() == reflect.Float32 || value.Kind() == reflect.Float64
}

func finiteFloat(value reflect.Value) bool {
	return !math.IsNaN(value.Float()) && !math.IsInf(value.Float(), 0)
}

func jsonEmpty(value reflect.Value) bool {
	switch value.Kind() {
	case reflect.Array, reflect.Map, reflect.Slice, reflect.String:
		return value.Len() == 0
	case reflect.Bool:
		return !value.Bool()
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return value.Int() == 0
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return value.Uint() == 0
	case reflect.Float32, reflect.Float64:
		return value.Float() == 0
	case reflect.Interface, reflect.Pointer:
		return value.IsNil()
	default:
		return false
	}
}
