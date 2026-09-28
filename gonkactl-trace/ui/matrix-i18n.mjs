// Translate presentation strings only. Raw JSON and log excerpts never enter this function.
const ru = new Map([
['Gonka · state matrix prototype','Gonka · матрица состояний'],
['Gonka · incident investigation · prototype','Gonka · расследование инцидента · прототип'],
['Open detailed timeline in Perfetto','Открыть подробную трассу в Perfetto'],
['Loading four-height state comparison…','Загрузка сравнения состояний на четырёх высотах…'],
['What changed at the halt boundary?','Что изменилось перед остановкой сети?'],
['H306550–H306553 · retained evidence, not live health or an independently verified incident conclusion','H306550–H306553 · сохранённые свидетельства, не текущее состояние сети и не независимо проверенное заключение'],
['First height in this prototype; the preceding state is not included','Первая высота в матрице, предыдущее состояние в неё не включено'],
['No membership or power change in the retained sets at this transition; this says nothing about signing availability','На этом переходе состав и веса не изменились, это не подтверждает доступность подписантов'],
['Application sequence before the validator update','Решения приложения перед обновлением валидаторов'],
['Historical application state collected later from REST; matching replies are corroborating reports, not independently verified state proofs','Историческое состояние приложения получено позже через REST, совпадающие ответы подтверждают согласованность сообщений, но не являются независимо проверенными доказательствами состояния'],
['H306529 · The previous application group is retained below; its weights are not the same thing as the live consensus set.','H306529 · Ниже показана предыдущая группа приложения, её веса нельзя отождествлять с весами действующего набора валидаторов'],
['H306529 · Previous application group is missing or conflicting.','H306529 · Данные предыдущей группы отсутствуют или противоречат друг другу'],
['PoC v2 input is missing or conflicting; no absence-of-participation conclusion is available.','Данные PoC v2 отсутствуют или противоречат друг другу, вывод об отсутствии участия сделать нельзя'],
['H306549 · New application group is missing or conflicting.','H306549 · Данные новой группы отсутствуют или противоречат друг другу'],
['H306551 → H306553 · The application update becomes effective in consensus; exact emitted changes are listed below. The group decision precedes this activation.','H306551 → H306553 · Обновление приложения вступает в силу в консенсусе, конкретные изменения приведены ниже, решение о группе принято до этого перехода'],
['After activation · Quorum arithmetic remains unavailable.','После применения · Недостаточно данных для расчёта кворума'],
['Participant','Участник'],['Previous group weight','Вес в прежней группе'],['New group weight','Вес в новой группе'],
['PoC v2 commit counts','Количество в PoC v2 commits'],['Validation reports','Результаты проверок'],['Application decision at H306548','Решение приложения на H306548'],
['unknown','неизвестно'],['not in group','нет в группе'],['no retained v2 commit','v2 commit в выборке отсутствует'],['no retained v2 validation','v2 validation в выборке отсутствует'],
['Rejected: no majority; inspect guardian counts','Отклонён: нет большинства, см. счётчики голосов guardians'],
['Decision log evidence','Строки журнала решения'],['No decision log in this selection','В выборке нет записи о решении'],
['Decision logs report rejection for lack of majority and preserved-participant reuse; this is more specific than a validator update. They do not prove why the missing PoC validations were not submitted, or independently reproduce the historical algorithm. Commit counts are not final voting power. Empty excluded_participants does not prove eligibility.','Журналы сообщают об отклонении из-за отсутствия большинства и переносе участников прежней эпохи, это объясняет решение подробнее, чем само обновление валидаторов, но не устанавливает причину недостающих PoC-проверок и не заменяет независимое воспроизведение алгоритма\n\nКоличество в commits не равно итоговому весу голоса, пустой excluded_participants не доказывает право на участие'],
['Application receipts behind this comparison','Ответы приложения, на которых основано сравнение'],['All application queries, gaps and parameters','Все запросы приложения, пробелы и параметры'],
['H306551 explicitly removes weights before H306553 activation','H306551: явное обнуление весов перед применением на H306553'],
['Zero is an explicit removal in the emitted update, not an inference from missing signatures. Application selection inputs are shown above when available.','Нулевой вес явно указан в обновлении, он не выведен из отсутствия подписей, доступные входные данные отбора показаны выше'],
['How could node5-2 enter the validator set without signing?','Как node5-2 вошла в набор валидаторов без подписи?'],
['Being assigned voting power and producing a consensus signature are separate steps. The existing validator set finalizes a block; the application returns a public key and power update. The incoming validator does not need to co-sign its own activation as a member of the old set.','Назначение веса и создание подписи консенсуса – разные действия, действующий набор валидаторов завершает блок, а приложение возвращает обновление публичного ключа и веса, входящий валидатор не обязан подписывать блок своего включения как участник прежнего набора'],
['Earlier membership is not established by this subset; this boundary must not be called the initial JOIN.','Эта выборка не устанавливает прежнее участие, данный переход нельзя называть первоначальным JOIN'],
['H306551 · A matching activation update is not established in this subset.','H306551 · В выборке не установлено соответствующее обновление для включения'],
['Old-set decision · A retained H306551 certificate reaches the old quorum without node5-2. No new-validator signature is needed to finalize that block.','Решение прежнего набора · Сохранённый сертификат H306551 достигает прежнего кворума без node5-2, для завершения этого блока подпись нового валидатора не нужна'],
['Old-set decision · Sufficient certificate evidence without node5-2 is not established here.','Решение прежнего набора · Здесь не установлен достаточный сертификат без node5-2'],
['After activation · Complete membership arithmetic is unavailable.','После применения · Полных данных о составе для расчёта нет'],
['No historical signing record for this identity is retained at H306553. This does not prove that the key never signed, or that no registration transaction was signed.','На H306553 в выборке нет исторической записи подписи этого ключа, это не доказывает, что ключ никогда не подписывал сообщения или что транзакция регистрации не была подписана'],
['Evidence for this explanation','Свидетельства для этого объяснения'],['Earlier retained set, not registration time','Прежний сохранённый набор, не время регистрации'],
['Application update → effective membership, with source references','Обновление приложения → действующий состав, со ссылками на источники'],
['Old-set certificate variants and observations','Варианты сертификатов прежнего набора и наблюдения'],['Before and after validator sets','Наборы валидаторов до и после изменения'],
['Still open: why Gonka assigned this identity positive weight again after the recorded jail, which registration/eligibility checks applied, and whether the intended signer key was available. This view does not reconstruct that application decision or prove key loss.','Остаются вопросы о правилах повторного назначения веса после jail, проверках регистрации и допуска, доступности ожидаемого ключа подписанта, показанные свидетельства не заменяют независимый пересчёт решения и не доказывают утрату ключа'],
['Protocol reference: CometBFT v0.38.21 · FinalizeBlock and ValidatorUpdate','Описание протокола: CometBFT v0.38.21 · FinalizeBlock и ValidatorUpdate'],
['Protocol context: ABCI updates carry a public key and voting power, not the incoming validator’s consensus signature; an update from H takes effect at H+2. This describes activation, not Gonka’s registration or proof-of-possession rules.','Контекст протокола: обновление ABCI содержит публичный ключ и вес, а не подпись консенсуса входящего валидатора, обновление с высоты H применяется на H+2, это описывает включение в набор, а не правила регистрации и подтверждения владения ключом в Gonka'],
['Why could node5-2 enter without signing? · activation is not signer readiness','Почему node5-2 вошла без подписи? · включение не подтверждает готовность подписанта'],
['Participant state by height','Состояния участников по высотам'],['Identity','Участник'],['Set missing or multiple versions','Набор отсутствует или имеет несколько версий'],['Epoch-change records','Записи о смене эпохи'],
['Not in complete set','Нет в полном наборе'],['≠ Conflicting evidence','≠ Противоречивые свидетельства'],['? Membership unknown','? Участие неизвестно'],
['No historical signing record in selection','В выборке нет исторической подписи'],['Earlier jail records · current status unknown','Прежние записи jail · текущий статус неизвестен'],
['“Not in complete set” concerns this consensus identity at this height, not whether a machine was running. No signing record does not prove inactivity.','«Нет в полном наборе» относится к ключу консенсуса на данной высоте, а не к работе машины, отсутствие записи подписи не доказывает бездействие'],
['Membership from retained V(H); no independent verification is performed by this screen','Состав взят из сохранённого V(H), этот экран не выполняет независимую проверку'],
['Identity attribution','Сопоставление участника и ключа'],['Validator set and its source references','Набор валидаторов и ссылки на источники'],['Historical signing evidence','Исторические свидетельства подписей'],
['Grouping preserves network, height, round, phase, block and identity; records remain below. Statement count is not confidence, quorum or proof of delivery','Группировка сохраняет сеть, высоту, раунд, фазу, блок и ключ, записи приведены ниже, их количество не является оценкой достоверности, кворумом или доказательством доставки'],
['Separate records, not a count of distinct jail episodes. Current jail status and its effect on membership are not inferred','Это отдельные записи, а не число различных эпизодов jail, текущий статус jail и его влияние на участие не выводятся из этих записей'],
['Inspect this height in Perfetto','Открыть эту высоту в Perfetto'],
['Historical subject, separate collection time. These records are not historical message delivery or continuation of the timeline','Данные относятся к прошлому, но собраны отдельно и позже, они не описывают историческую доставку сообщений и не продолжают трассу'],
['Coverage, attribution and open questions','Покрытие, сопоставление участников и открытые вопросы'],
['This prototype covers four heights, plus earlier retained jail records. It does not establish the earliest node2 participation, reset timing, or post-halt synchronization','Матрица охватывает четыре высоты и прежние записи jail, она не устанавливает начало участия node2, момент сброса или синхронизацию после остановки'],
['Retained excerpt below; this viewer does not open the full original file','Ниже сохранённый фрагмент, этот экран не открывает исходный файл целиком'],
['No excerpt retained; original file is not opened by this viewer','Фрагмент не сохранён, этот экран не открывает исходный файл'],
['Some referenced observations are unavailable in this subset','Часть указанных наблюдений недоступна в этой выборке'],
['Previous records','Предыдущие записи'],['Next records','Следующие записи'],['Invalid session','Неверный идентификатор сессии'],['Dataset mismatch','Набор данных не соответствует сессии'],
]);

const patterns = [
 [/^In set · power (.+)$/,(_,p)=>`В наборе · вес ${p}`],
 [/^Baseline H(\d+)$/,(_,h)=>`Исходное состояние H${h}`],
 [/^PoC stage (\d+) · Retained v2 commitments and validation reports are compared below\. A commitment is not successful admission\.$/,(_,h)=>`Этап PoC ${h} · Ниже сопоставлены сохранённые commits v2 и результаты проверок, отправка commit не означает успешный допуск`],
 [/^By H306549 · Application group (\d+), epoch (\d+), reports total weight (\d+)\. The participant comparison shows who is no longer in this group\.$/,(_,g,e,w)=>`К H306549 · Группа приложения ${g}, эпоха ${e}, сообщает общий вес ${w}, сравнение показывает, кто больше не входит в группу`],
 [/^After activation · Other members have at most (\d+) voting power against quorum (\d+), conditional on node5-2 not signing\.$/,(_,p,q)=>`После применения · Если node5-2 не подписывает, остальным доступен вес не более ${p} при кворуме ${q}`],
 [/^Accepted: (\d+)\/(\d+) valid slots$/,(_,a,b)=>`Принят: положительных слотов ${a} из ${b}`],
 [/^Preserved from previous epoch: (.+)$/,(_,p)=>`Перенесён из предыдущей эпохи: ${p}`],
 [/^Weight pipeline: (.+)$/,(_,p)=>`Расчёт веса: ${p}`], [/^PoC contribution: (.+)$/,(_,p)=>`Вклад PoC: ${p}`],
 [/^Total (.+) · quorum (.+)$/,(_,p,q)=>`Общий вес ${p} · кворум ${q}`],
 [/^Certificate evidence: (\d+) statements?$/,(_,n)=>`Записей в сертификатах: ${n}`],
 [/^Signer records: (\d+)$/,(_,n)=>`Записей подписанта: ${n}`],
 [/^(\d+) certificate statements · (\d+) local signer records$/,(_,n,m)=>`Записей сертификатов: ${n} · локальных записей подписанта: ${m}`],
 [/^Earlier jail records \((\d+)\) · duration not established$/,(_,n)=>`Прежние записи jail (${n}) · длительность не установлена`],
 [/^Separate snapshot evidence at H(\d+) \((\d+) records\)$/,(_,h,n)=>`Отдельные снимки состояния H${h} (${n} записей)`],
 [/^(\d+) records · page (\d+)\/(\d+)$/,(_,n,p,total)=>`Записей: ${n} · страница ${p} из ${total}`],
 [/^H306551 · The retained application update assigns node5-2 power (\d+); its activation is matched to H306553\.$/,(_,p)=>`H306551 · Сохранённое обновление приложения назначает node5-2 вес ${p}, применение сопоставлено с H306553`],
 [/^Earlier history: this identity already appears with positive power at retained H(\d+)\. (.+)$/,(_,h,tail)=>`Предыстория: этот ключ уже встречается с положительным весом на сохранённой высоте H${h}, ${tail.startsWith('H306553 is')?'H306553 – возвращение в активный набор, а не первоначальный JOIN или регистрация':'повторное включение на этой границе не установлено выбранными наборами'}`],
 [/^H306553 · (.+)\. This is an assignment of voting power, not proof that its signer is working\.$/,(_,s)=>`H306553 · ${translate(s,'ru')}, это назначение веса, а не доказательство работы подписанта`],
 [/^After activation · Even if every other member signs, their combined power is (\d+); quorum is (\d+)\. (.+)$/,(_,p,q,tail)=>`После применения · Даже если все остальные подпишут, их общий вес составит ${p} при кворуме ${q}, ${tail.startsWith('They cannot')?'без дополнительного веса подписей они не смогут завершить блок':'одного этого расчёта недостаточно для вывода о потере кворума'}`],
 [/^The selected height contains (\d+) historical signing records for this identity; inspect their verification and derivation\.$/,(_,n)=>`На выбранной высоте есть ${n} исторических записей подписи этого ключа, проверьте их происхождение и статус проверки`],
 [/^Source: (.*)$/,(_,s)=>`Источник: ${s==='not retained'?'не сохранён':s}`],
 [/^Observation time: (.*)$/,(_,s)=>`Время наблюдения: ${s==='unknown'?'неизвестно':s}`],
 [/^Event time: (.*) · (\d+) observation references, not independent confirmations$/,(_,s,n)=>`Время события: ${s==='unknown'?'неизвестно':s} · ссылок на наблюдения: ${n}, это не независимые подтверждения`],
 [/^Derivation: (.*)$/,(_,s)=>`Происхождение: ${s}`],
 [/^Matrix unavailable: (.*)$/,(_,s)=>`Матрица недоступна: ${translate(s,'ru')}`],
];

export function translate(value,language='en') {
 if(language!=='ru'||typeof value!=='string')return value;
 if(ru.has(value))return ru.get(value);
 for(const [pattern,render] of patterns){const match=value.match(pattern);if(match)return render(...match);}
 return value.replace(/comparison unknown/g,'сравнение неизвестно').replace(/\bout\b/g,'вне набора')
  .replace(/ \(self\)/g,' (собственная проверка)').replace(/ · update match /g,' · соответствие обновлению ')
  .replace(/ · collected /g,' · собрано ').replace(/ · observer /g,' · наблюдатель ')
  .replace(/ · power /g,' · вес ').replace(/ \/ quorum /g,' / кворум ')
  .replace(/verification unknown/g,'статус проверки неизвестен');
}

export function chooseLanguage(search,stored,browser='en') {
 const requested=new URLSearchParams(search).get('lang');
 return ['ru','en'].includes(requested)?requested:['ru','en'].includes(stored)?stored:browser.toLowerCase().startsWith('ru')?'ru':'en';
}
