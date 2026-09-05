package singbox

import "testing"

func TestImportRejectsPortOverflowBeforeUint16Conversion(t *testing.T) {
	for _, port := range []float64{0, -1, 65536, 65537} {
		_, err := Import(map[string]interface{}{"outbounds": []interface{}{map[string]interface{}{
			"tag": "node", "type": "vless", "server": "127.0.0.1", "server_port": port, "uuid": "00000000-0000-0000-0000-000000000001",
		}}})
		if err == nil {
			t.Fatalf("accepted invalid port %.0f", port)
		}
	}
}
