//! Experimental direct native AX snapshots over the existing paired service.
//! Wire schema: https://github.com/ipbtools/ipb/blob/main/docs/protocol.md
//! This does not start XCTest or send text through an accessibility action.
use super::*;

pub struct Direct {
    socket: Box<dyn ReadWrite>,
    objects: Vec<Value>,
    root: Value,
    pid: u64,
    object_id: u64,
    orientation: u64,
    next_id: u32,
}
fn dictionary(entries: impl IntoIterator<Item = (&'static str, Value)>) -> Value {
    Value::Dictionary(
        entries
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v))
            .collect(),
    )
}
fn add(objects: &mut Vec<Value>, value: Value) -> Value {
    let id = objects.len();
    objects.push(value);
    Value::Uid(plist::Uid::new(id as u64))
}
fn class(objects: &mut Vec<Value>, name: &str) -> Value {
    add(
        objects,
        dictionary([
            ("$classname", name.into()),
            (
                "$classes",
                Value::Array(vec![name.into(), "NSObject".into()]),
            ),
        ]),
    )
}
fn encode(objects: &mut Vec<Value>, value: Value) -> Value {
    match value {
        Value::Dictionary(values) => {
            let mut keys = Vec::new();
            let mut vals = Vec::new();
            for (key, value) in values {
                keys.push(encode(objects, key.into()));
                vals.push(encode(objects, value));
            }
            let cls = class(objects, "NSDictionary");
            add(
                objects,
                dictionary([
                    ("NS.keys", Value::Array(keys)),
                    ("NS.objects", Value::Array(vals)),
                    ("$class", cls),
                ]),
            )
        }
        Value::Array(values) => {
            let items = values.into_iter().map(|v| encode(objects, v)).collect();
            let cls = class(objects, "NSArray");
            add(
                objects,
                dictionary([("NS.objects", Value::Array(items)), ("$class", cls)]),
            )
        }
        other => add(objects, other),
    }
}
impl Direct {
    pub async fn connect(adapter: &mut AdapterHandle, rsd: &RsdHandshake) -> Result<Self> {
        let port = rsd
            .services
            .get("com.apple.accessibility.axAuditDaemon.remoteAXService")
            .ok_or("Native accessibility service is unavailable")?
            .port;
        let mut socket: Box<dyn ReadWrite> = Box::new(adapter.connect(port).await?);
        call(
            &mut socket,
            1,
            "_notifyOfPublishedCapabilities:",
            dictionary([
                ("com.apple.private.DTXBlockCompression", 0.into()),
                ("com.apple.private.DTXConnection", 1.into()),
            ]),
            false,
        )
        .await?;
        call(
            &mut socket,
            2,
            "clientNeedsAccessibility:",
            true.into(),
            true,
        )
        .await?;
        let mut tree = Tree::default();
        let mut root_archive = None;
        loop {
            let message = Message::from_reader(&mut socket).await?;
            acknowledge(&mut socket, &message).await?;
            let Some(update) = response(&message)? else {
                continue;
            };
            tree.update(&update)?;
            if let Some(result) = update.field(update.root(), "resultData") {
                if let Some(dump) = update.field(result, "treeDump") {
                    for item in update.array(dump) {
                        if update
                            .field(item, "associatedRequestType")
                            .and_then(|v| update.integer(v))
                            == Some(4)
                        {
                            if let Some(token) = update.field(item, "resultData") {
                                if let (Some(pid), Some(id)) = (
                                    update.field(token, "pid").and_then(|v| update.integer(v)),
                                    update
                                        .field(token, "objectID")
                                        .and_then(|v| update.integer(v)),
                                ) {
                                    root_archive = Some((
                                        update.value.as_dictionary().unwrap()["$objects"]
                                            .as_array()
                                            .unwrap()
                                            .clone(),
                                        token.clone(),
                                        pid,
                                        id,
                                    ));
                                }
                            }
                        }
                    }
                }
            }
            if tree.ready() {
                let (objects, root, pid, object_id) =
                    root_archive.take().ok_or("No live application token")?;
                return Ok(Self {
                    socket,
                    objects,
                    root,
                    pid,
                    object_id,
                    orientation: tree.orientation.ok_or("No display orientation")?,
                    next_id: 10,
                });
            }
        }
    }
    pub async fn snapshot(&mut self) -> Result<Json> {
        // A nil snapshot is a transient read failure, not permission to replay input.
        for attempt in 0..3 {
            match self.snapshot_once().await {
                Err(error) if error.to_string() == "Direct snapshot unavailable" && attempt < 2 => continue,
                result => return result,
            }
        }
        unreachable!()
    }

    async fn snapshot_once(&mut self) -> Result<Json> {
        // Preserve the complete native token and every UID it references.
        let mut objects = self.objects.clone();
        let token = add(&mut objects, self.root.clone());
        let options = dictionary([
            (
                "attributes",
                Value::Array(
                    [2001, 2003, 2004, 5019, 2006, 3002]
                        .into_iter()
                        .map(Value::from)
                        .collect(),
                ),
            ),
            ("maxDepth", 48.into()),
            ("maxChildren", 512.into()),
            ("maxArrayCount", 512.into()),
            ("traverseFromParentsToChildren", true.into()),
            ("snapshotKeyHonorModalViews", false.into()),
        ]);
        let parameters = encode(&mut objects, dictionary([("parameter", options)]));
        let cls = class(&mut objects, "AXPTranslatorRequest");
        let request = add(
            &mut objects,
            dictionary([
                ("requestType", 2.into()),
                ("attributeType", 52.into()),
                ("actionType", 0.into()),
                ("clientType", 0.into()),
                ("translation", token),
                ("parameters", parameters),
                ("$class", cls),
            ]),
        );
        let archive = dictionary([
            ("$version", 100000.into()),
            ("$archiver", "NSKeyedArchiver".into()),
            ("$top", dictionary([("root", request)])),
            ("$objects", Value::Array(objects)),
        ]);
        let mut bytes = Vec::new();
        archive.to_writer_binary(&mut bytes)?;
        let id = self.next_id;
        self.next_id += 1;
        call(
            &mut self.socket,
            id,
            "processDataFromHost:",
            Value::Data(bytes),
            true,
        )
        .await?;
        loop {
            let message = Message::from_reader(&mut self.socket).await?;
            acknowledge(&mut self.socket, &message).await?;
            let Some(update) = response(&message)? else {
                continue;
            };
            self.observe_metadata(&update)?;
            if update
                .field(update.root(), "associatedRequestType")
                .and_then(|v| update.integer(v))
                != Some(2)
            {
                continue;
            }
            let result = update
                .field(update.root(), "resultData")
                .ok_or("Direct AX snapshot has no result")?;
            let result = flatten(&update, result, self.pid, self.object_id, self.orientation)?;
            if let Some(field) = result["elements"]
                .as_array()
                .and_then(|items| items.iter().find(|v| v["focused"] == true))
            {
                let f = &field["frame"];
                let mut left = f["x"].as_f64().ok_or("No focused field frame")?;
                let mut top = f["y"].as_f64().ok_or("No focused field frame")?;
                let mut right = left + f["width"].as_f64().ok_or("No focused field width")?;
                let mut bottom = top + f["height"].as_f64().ok_or("No focused field height")?;
                let bounds = &result["elements"][0]["frame"];
                if let (Some(x), Some(y), Some(w), Some(h)) = (
                    bounds["x"].as_f64(),
                    bounds["y"].as_f64(),
                    bounds["width"].as_f64(),
                    bounds["height"].as_f64(),
                ) {
                    left = left.max(x);
                    top = top.max(y);
                    right = right.min(x + w);
                    bottom = bottom.min(y + h);
                }
                if right <= left || bottom <= top {
                    return Err("Focused field is outside the visible app".into());
                }
                let x = (left + right) / 2.;
                let y = top + (bottom - top) / 4.;
                self.verify_visible_app(x, y).await?;
            }
            return Ok(result);
        }
    }
    async fn verify_visible_app(&mut self, x: f64, y: f64) -> Result<()> {
        let mut objects = vec![Value::from("$null")];
        let point_text = add(&mut objects, format!("{{{x}, {y}}}").into());
        let point_class = class(&mut objects, "NSValue");
        let point = add(
            &mut objects,
            dictionary([
                ("NS.pointval", point_text),
                ("NS.special", 1.into()),
                ("$class", point_class),
            ]),
        );
        let point_key = add(&mut objects, "point".into());
        let display_key = add(&mut objects, "displayId".into());
        let display = add(&mut objects, 0.into());
        let dict_class = class(&mut objects, "NSDictionary");
        let parameters = add(
            &mut objects,
            dictionary([
                ("NS.keys", Value::Array(vec![point_key, display_key])),
                ("NS.objects", Value::Array(vec![point, display])),
                ("$class", dict_class),
            ]),
        );
        // The documented hit-test carrier is deliberately blank, not a live-node token.
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos() as u64;
        let object_id = add(&mut objects, nonce.into());
        let token_class = class(&mut objects, "AXPTranslationObject");
        let token = add(
            &mut objects,
            dictionary([
                ("objectID", object_id),
                ("pid", 0.into()),
                ("isApplicationElement", false.into()),
                ("didPopuldateAppInfo", false.into()),
                ("bridgeDelegateToken", Value::Uid(plist::Uid::new(0))),
                ("rawElementData", Value::Uid(plist::Uid::new(0))),
                ("$class", token_class),
            ]),
        );
        let cls = class(&mut objects, "AXPTranslatorRequest");
        let request = add(
            &mut objects,
            dictionary([
                ("requestType", 6.into()),
                ("attributeType", 0.into()),
                ("actionType", 0.into()),
                ("clientType", 0.into()),
                ("translation", token),
                ("parameters", parameters),
                ("$class", cls),
            ]),
        );
        let archive = dictionary([
            ("$version", 100000.into()),
            ("$archiver", "NSKeyedArchiver".into()),
            ("$top", dictionary([("root", request)])),
            ("$objects", Value::Array(objects)),
        ]);
        let mut bytes = Vec::new();
        archive.to_writer_binary(&mut bytes)?;
        let id = self.next_id;
        self.next_id += 1;
        call(
            &mut self.socket,
            id,
            "processDataFromHost:",
            Value::Data(bytes.clone()),
            true,
        )
        .await?;
        let mut retries = 0;
        loop {
            let message = Message::from_reader(&mut self.socket).await?;
            acknowledge(&mut self.socket, &message).await?;
            let Some(update) = response(&message)? else {
                continue;
            };
            self.observe_metadata(&update)?;
            if update
                .field(update.root(), "associatedRequestType")
                .and_then(|v| update.integer(v))
                != Some(6)
            {
                continue;
            }
            let pid = update
                .field(update.root(), "resultData")
                .and_then(|v| update.field(v, "pid"))
                .and_then(|v| update.integer(v));
            if pid != Some(self.pid) && retries < 2 {
                retries += 1;
                let id = self.next_id;
                self.next_id += 1;
                call(
                    &mut self.socket,
                    id,
                    "processDataFromHost:",
                    Value::Data(bytes.clone()),
                    true,
                )
                .await?;
                continue;
            }
            if pid != Some(self.pid) {
                return Err(format!("Typing-app visibility could not be verified (expected PID {}, observed {:?}, point {x},{y})",self.pid,pid).into());
            }
            return Ok(());
        }
    }
    fn observe_metadata(&mut self, update: &Archive) -> Result<()> {
        if update
            .field(update.root(), "associatedRequestType")
            .and_then(|v| update.integer(v))
            != Some(11)
        {
            return Ok(());
        }
        let Some(dump) = update
            .field(update.root(), "resultData")
            .and_then(|v| update.field(v, "treeDump"))
        else {
            return Ok(());
        };
        for item in update.array(dump) {
            let kind = update
                .field(item, "associatedRequestType")
                .and_then(|v| update.integer(v));
            let Some(value) = update.field(item, "resultData") else {
                continue;
            };
            if kind == Some(4)
                && update.field(value, "pid").and_then(|v| update.integer(v)) != Some(self.pid)
            {
                return Err("Foreground application changed during native typing".into());
            }
            if kind == Some(2)
                && update
                    .field(item, "attribute")
                    .and_then(|v| update.integer(v))
                    == Some(129)
            {
                self.orientation = update.integer(value).ok_or("Unknown display orientation")?;
            }
        }
        Ok(())
    }
    pub async fn close(&mut self) -> Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        call(
            &mut self.socket,
            id,
            "clientNeedsAccessibility:",
            false.into(),
            true,
        )
        .await?;
        self.socket.shutdown().await?;
        Ok(())
    }
}
fn response(message: &Message) -> Result<Option<Archive>> {
    let Some(AuxValue::Array(bytes)) = message.aux.as_ref().and_then(|a| a.values.first()) else {
        return Ok(None);
    };
    let outer = Archive::parse(bytes)?;
    let Some(data) = outer.data(outer.root()) else {
        return Ok(None);
    };
    Ok(Some(Archive::parse(data)?))
}
fn attribute<'a>(a: &'a Archive, attrs: &'a Value, id: u64) -> Option<&'a Value> {
    a.entries(attrs)
        .into_iter()
        .find(|(key, _)| a.integer(key) == Some(id))
        .map(|(_, v)| v)
}
fn flatten(
    a: &Archive,
    root: &Value,
    pid: u64,
    expected_id: u64,
    orientation: u64,
) -> Result<Json> {
    let token = a
        .field(root, "UIAccessibilitySnapshotKeyElement")
        .ok_or("Direct snapshot unavailable")?;
    if a.field(token, "objectID").and_then(|v| a.integer(v)) != Some(expected_id) {
        return Err("Direct snapshot root changed".into());
    }
    let attrs = a
        .field(root, "UIAccessibilitySnapshotKeyAttributes")
        .ok_or("No root attributes")?;
    let responder_id = attribute(a, attrs, 3002)
        .and_then(|r| a.field(r, "UIAccessibilitySnapshotKeyElement"))
        .and_then(|t| a.field(t, "objectID"))
        .and_then(|v| a.integer(v));
    let mut tree = Tree {
        roots: vec![(expected_id, Some(pid))],
        orientation: Some(orientation),
        ..Tree::default()
    };
    let mut pending = vec![(root, 0)];
    while let Some((record, depth)) = pending.pop() {
        if depth > 48 || tree.nodes.len() >= 512 {
            return Err("Direct snapshot exceeds bounds".into());
        }
        let token = a
            .field(record, "UIAccessibilitySnapshotKeyElement")
            .ok_or("Missing snapshot element")?;
        let id = a
            .field(token, "objectID")
            .and_then(|v| a.integer(v))
            .ok_or("Missing element identity")?;
        let attrs = a
            .field(record, "UIAccessibilitySnapshotKeyAttributes")
            .ok_or("Missing element attributes")?;
        let children_value = a
            .field(record, "UIAccessibilitySnapshotKeyChildren")
            .ok_or("Missing snapshot children")?;
        let children = a.array(children_value);
        if a.field(record, "UIAccessibilitySnapshotKeyChildrenCount")
            .and_then(|v| a.integer(v))
            != Some(children.len() as u64)
        {
            return Err("Truncated snapshot children".into());
        }
        let mut node = Node::default();
        for (number, name) in [(2001, "label"), (5019, "identifier"), (2006, "value")] {
            if let Some(value) = attribute(a, attrs, number).and_then(|v| a.string(v)) {
                node.fields.insert(name.into(), value.into());
            }
        }
        if let Some(value) = attribute(a, attrs, 2003) {
            let f = a.numbers(value);
            if f.len() == 4 {
                node.fields.insert(
                    "frame".into(),
                    json!({"x":f[0],"y":f[1],"width":f[2],"height":f[3]}),
                );
            }
        }
        if let Some(traits) = attribute(a, attrs, 2004).and_then(|v| a.integer(v)) {
            node.fields.insert("traits".into(), traits.into());
            if is_editing(traits) {
                node.fields.insert("role".into(), "TextField".into());
            }
        }
        node.fields
            .insert("focused".into(), (Some(id) == responder_id).into());
        for child in children {
            let child_id = a
                .field(child, "UIAccessibilitySnapshotKeyElement")
                .and_then(|t| a.field(t, "objectID"))
                .and_then(|v| a.integer(v))
                .ok_or("Missing child identity")?;
            node.children.push(child_id);
            pending.push((child, depth + 1));
        }
        tree.nodes.insert(id, node);
    }
    let mut json = tree.json();
    // Direct snapshot focus comes from the actual root first responder, not a trait approximation.
    for item in json["elements"].as_array_mut().unwrap() {
        item["focused"] = (item["object_id"].as_str()
            == responder_id.map(|id| format!("o{id}")).as_deref())
        .into();
    }
    json["direct"] = true.into();
    Ok(json)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn attrs(values: Vec<(u64, Value)>) -> Value {
        let (keys, values): (Vec<_>, Vec<_>) =
            values.into_iter().map(|(k, v)| (Value::from(k), v)).unzip();
        dictionary([
            ("NS.keys", Value::Array(keys)),
            ("NS.objects", Value::Array(values)),
        ])
    }
    fn record(id: u64, attributes: Value, children: Vec<Value>) -> Value {
        dictionary([
            (
                "UIAccessibilitySnapshotKeyElement",
                dictionary([("objectID", id.into()), ("pid", 42.into())]),
            ),
            ("UIAccessibilitySnapshotKeyAttributes", attributes),
            (
                "UIAccessibilitySnapshotKeyChildrenCount",
                (children.len() as u64).into(),
            ),
            ("UIAccessibilitySnapshotKeyChildren", Value::Array(children)),
        ])
    }
    fn fixture(responder: bool) -> (Archive, Value) {
        let field = record(
            u64::MAX - 1,
            attrs(vec![
                (2004, (1u64 << 21).into()),
                (2006, "你好".into()),
                (2003, "{{10, 20}, {300, 400}}".into()),
            ]),
            vec![],
        );
        let attributes = if responder {
            attrs(vec![(3002, field.clone())])
        } else {
            attrs(vec![])
        };
        let root = record(10, attributes, vec![field]);
        (
            Archive {
                value: dictionary([("$objects", Value::Array(vec!["$null".into()]))]),
            },
            root,
        )
    }
    #[test]
    fn direct_focus_requires_first_responder_not_editing_trait() {
        for responder in [false, true] {
            let (archive, root) = fixture(responder);
            let json = flatten(&archive, &root, 42, 10, 3).unwrap();
            let field = &json["elements"][1];
            assert_eq!(field["object_id"], format!("o{}", u64::MAX - 1));
            assert_eq!(field["value"], "你好");
            assert_eq!(field["focused"], responder);
        }
    }
    #[test]
    fn direct_snapshot_rejects_wrong_root_and_truncated_children() {
        let (archive, mut root) = fixture(true);
        assert!(flatten(&archive, &root, 42, 11, 3).is_err());
        root.as_dictionary_mut()
            .unwrap()
            .insert("UIAccessibilitySnapshotKeyChildrenCount".into(), 2.into());
        assert!(flatten(&archive, &root, 42, 10, 3).is_err());
    }
}
