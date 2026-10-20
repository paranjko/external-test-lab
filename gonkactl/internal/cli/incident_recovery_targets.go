//go:build gnklab0002_live

package cli

// Exact targets observed on the current stand; this is not an arbitrary-host API.
type incidentRecoveryTarget struct {
	Original   string
	Image      string
	Entrypoint string
	Consumers  string
}

var incidentRecoveryTargets = map[string]incidentRecoveryTarget{
	"node0":  {Original: "8cf81711876ced5890360743474a5aa08824e2f01746c14090f86427dad44a88", Image: "sha256:9d0db1ba02d2b661c6e1add1a32467ccd1a23572639d90ded19c3c31d272851e", Entrypoint: "[\"/root/.inference/cosmovisor/upgrades/v0.2.16/bin/inferenced\"]", Consumers: "b1b1bd47dd2960b7703fabb9944a97360054e24f37827e9329c8e294694903aa|d5c73ddba3cb4f54b16a71031ea52938bc8056941809d9f6799a771ddd480acf"},
	"node2":  {Original: "e5409c11e27c78b267109dd0784f2f5dd860b89f4925785826f7846b49635bc0", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "5ceaa8f385a6c7720d6afabbd47feb0b947f8f0810c0511d85686bbfec49bfb6|e6707facca1335f69ed574dc6475a13f43121eaadd5583202b5266f0b3d380a6"},
	"node3":  {Original: "6243ac9f94635870d1cd7c7d3438e379ed09add9e2ac1a3f88f59fed01f93c08", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "88023edb3fe41c2387cbb0070a9ab2f4c97c4d3511118021c65996e0dbf75ef7|8c3780c55842c8125ecb4be56791580788fd6e117b0ef8b017779bbd2f971985"},
	"node5":  {Original: "25eb385f1817148fba26172191014cee099061260481c3e4515c674b4666546b", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "937fcd92deb3a6722aec2e02e71a6984e111a87dc0e7043431c25aa60fc483f1|9cdf27ac1eada13cd33f8b7c9447dfb749f4e7a70566f0c20ac14645396fcedb"},
	"node6":  {Original: "ba8b56726690fd94e4f7a5bfe8104abbf53e2dad9d4ec1c9c701efc4ad52cf28", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "07b962e9424a4b6347f0a6e02c2d2b33d64f8d7658519e0fdc97085cd5829942|39b2db59a9f1c1c7cd2d75e5e8f471b92ed0b637275f81267f26c9df97ec86d5"},
	"node7":  {Original: "f2164a09699cceda803e42d5037f5550b669f64af466858ca7654c7f0cb3635d", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "5e4d9e332c21dcf3a39dac0b2dea40ed66ae132730283075720f00c1f1d22800|d69bc6056c8aa9fb12d2ccc971e3bebcd935081180cd4ef2afe22788659cbb20"},
	"node8":  {Original: "5dfc1bd6d1a18eb19af57fb93c10ce6a2bcddc52cc518b3ec06d0679181f6a55", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "0b0f354d700dba4d239c2ead9deec7736ee0892edbd4928094140e21e1e208de|26a00ee7185a5b042981d2610062ab3fcd2f0bcd0331ef33a195d8d36daaae9f"},
	"node10": {Original: "7190b67d94a406b9209e06d20af5db32a25a51883689967bd71104aba7f7b0bf", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "48e7d87e44b9b415f12fc85eaa7ebb5fffbd951b567b5de15e14006e2e649473|a1caf78a6a8bac5e7587f72e5a08fc08e587236abf23d4288df6c154afecb3e8"},
	"node11": {Original: "348210ce23903b35dae10b5702239900ef66fb3bcbe64b490187f2bf5fd6b739", Image: "sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112", Entrypoint: "null", Consumers: "5fdb0a0237e1655f3de4452194c11cc5cc2e14496bf1205252fe1237fd1300cb|9bf341d9efffb4655de4a4a7f813013c17ac4f858bebb113d4184575e3e4a242"},
}
