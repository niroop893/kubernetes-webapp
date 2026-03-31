const express = require('express');
const bodyParser = require('body-parser');
const bcrypt = require('bcryptjs');
const { MongoClient, ObjectId } = require('mongodb');
const path = require('path');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const fileUpload = require('express-fileupload');
const fs = require('fs');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  },
  pingTimeout: 60000,
  pingInterval: 25000
});

const PORT = 3000;

// Middleware
app.use(cors());
app.use(bodyParser.json({ limit: '50mb' }));
app.use(bodyParser.urlencoded({ extended: true, limit: '50mb' }));
app.use(express.static('public'));
app.use(fileUpload({
  limits: { fileSize: 10 * 1024 * 1024 }, // 10MB max
  useTempFiles: true,
  tempFileDir: '/tmp/'
}));

// Create uploads directory if it doesn't exist
const uploadsDir = path.join(__dirname, 'public', 'uploads');
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}

// MongoDB Connection
const MONGODB_USERNAME = process.env.MONGODB_USERNAME || 'admin';
const MONGODB_PASSWORD = process.env.MONGODB_PASSWORD || 'password123';
const MONGODB_HOST = process.env.MONGODB_HOST || 'localhost';
const MONGODB_PORT = process.env.MONGODB_PORT || '27017';
const MONGODB_DATABASE = process.env.MONGODB_DATABASE || 'webappdb';

const mongoUrl = `mongodb://${MONGODB_USERNAME}:${MONGODB_PASSWORD}@${MONGODB_HOST}:${MONGODB_PORT}`;

let db;
let usersCollection;
let messagesCollection;
let chatRoomsCollection;
let reactionsCollection;
let readReceiptsCollection;

// Store online users with their status
const onlineUsers = new Map(); // socketId -> { userId, userName, email, status, room }
const userSocketMap = new Map(); // userId -> socketId

// Connect to MongoDB
async function connectToMongo() {
  try {
    const client = new MongoClient(mongoUrl, {
      serverSelectionTimeoutMS: 5000,
      socketTimeoutMS: 45000,
    });

    await client.connect();
    console.log('Connected to MongoDB successfully');

    db = client.db(MONGODB_DATABASE);
    usersCollection = db.collection('users');
    messagesCollection = db.collection('messages');
    chatRoomsCollection = db.collection('chatrooms');
    reactionsCollection = db.collection('reactions');
    readReceiptsCollection = db.collection('readreceipts');

    // Create indexes
    await usersCollection.createIndex({ email: 1 }, { unique: true });
    await messagesCollection.createIndex({ timestamp: -1 });
    await messagesCollection.createIndex({ room: 1, timestamp: -1 });
    await messagesCollection.createIndex({ 
      userName: 'text', 
      message: 'text' 
    });
    await chatRoomsCollection.createIndex({ name: 1 }, { unique: true });
    await reactionsCollection.createIndex({ messageId: 1 });
    await readReceiptsCollection.createIndex({ messageId: 1, userId: 1 });

    // Create default chat rooms
    const defaultRooms = [
      { name: 'general', description: 'General Discussion', icon: '💬', createdAt: new Date() },
      { name: 'random', description: 'Random Chat', icon: '🎲', createdAt: new Date() },
      { name: 'tech', description: 'Technology Talk', icon: '💻', createdAt: new Date() },
      { name: 'fun', description: 'Fun & Games', icon: '🎮', createdAt: new Date() }
    ];

    for (const room of defaultRooms) {
      await chatRoomsCollection.updateOne(
        { name: room.name },
        { $setOnInsert: room },
        { upsert: true }
      );
    }

  } catch (error) {
    console.error('MongoDB connection error:', error);
    setTimeout(connectToMongo, 5000);
  }
}

connectToMongo();

// Socket.IO connection handling
io.on('connection', (socket) => {
  console.log('User connected:', socket.id);

  // User joins chat
  socket.on('user-join', async (userData) => {
    console.log('User joined:', userData);
    
    const userInfo = {
      userId: userData.userId || userData.id,
      userName: userData.name,
      email: userData.email,
      status: 'online',
      room: 'general',
      socketId: socket.id
    };

    onlineUsers.set(socket.id, userInfo);
    userSocketMap.set(userInfo.userId, socket.id);

    // Join default room
    socket.join('general');

    // Update user status in database
    await usersCollection.updateOne(
      { email: userData.email },
      { 
        $set: { 
          status: 'online',
          lastSeen: new Date(),
          socketId: socket.id
        } 
      }
    );

    // Broadcast to all clients
    io.emit('user-joined', {
      userName: userData.name,
      userId: userInfo.userId,
      status: 'online',
      onlineCount: onlineUsers.size
    });

    // Send current online users
    const onlineUsersList = Array.from(onlineUsers.values()).map(u => ({
      userId: u.userId,
      userName: u.userName,
      email: u.email,
      status: u.status
    }));
    socket.emit('online-users', onlineUsersList);

    // Send online count
    io.emit('online-count', onlineUsers.size);

    // Send available rooms
    const rooms = await chatRoomsCollection.find({}).toArray();
    socket.emit('available-rooms', rooms);
  });

  // Change user status
  socket.on('change-status', async (status) => {
    const user = onlineUsers.get(socket.id);
    if (user) {
      user.status = status;
      onlineUsers.set(socket.id, user);

      await usersCollection.updateOne(
        { email: user.email },
        { $set: { status: status } }
      );

      io.emit('user-status-changed', {
        userId: user.userId,
        userName: user.userName,
        status: status
      });
    }
  });

  // Join a chat room
  socket.on('join-room', async (roomName) => {
    const user = onlineUsers.get(socket.id);
    if (user) {
      // Leave current room
      socket.leave(user.room);

      // Join new room
      socket.join(roomName);
      user.room = roomName;
      onlineUsers.set(socket.id, user);

      socket.emit('room-joined', { room: roomName });

      // Notify room
      io.to(roomName).emit('user-joined-room', {
        userName: user.userName,
        room: roomName
      });

      // Load room messages
      const messages = await messagesCollection
        .find({ room: roomName })
        .sort({ timestamp: -1 })
        .limit(50)
        .toArray();

      socket.emit('room-messages', messages.reverse());
    }
  });

  // Send message (room or private)
  socket.on('send-message', async (data) => {
    try {
      const user = onlineUsers.get(socket.id);
      if (!user) {
        socket.emit('error', { message: 'User not authenticated' });
        return;
      }

      const message = {
        userName: user.userName,
        email: user.email,
        userId: user.userId,
        message: data.message,
        room: data.room || user.room,
        isPrivate: data.isPrivate || false,
        recipientId: data.recipientId || null,
        recipientName: data.recipientName || null,
        type: data.type || 'text', // text, image, file, voice
        fileUrl: data.fileUrl || null,
        fileName: data.fileName || null,
        timestamp: new Date(),
        edited: false,
        editedAt: null
      };

      // Save to database
      const result = await messagesCollection.insertOne(message);
      message._id = result.insertedId;

      // Send message
      if (message.isPrivate && message.recipientId) {
        // Private message
        const recipientSocketId = userSocketMap.get(message.recipientId);
        
        // Send to recipient
        if (recipientSocketId) {
          io.to(recipientSocketId).emit('new-message', {
            ...message,
            isOwnMessage: false
          });
        }

        // Send confirmation to sender
        socket.emit('new-message', {
          ...message,
          isOwnMessage: true
        });

      } else {
        // Room message
        io.to(message.room).emit('new-message', {
          ...message,
          isOwnMessage: false
        });

        socket.emit('message-sent', {
          id: message._id,
          timestamp: message.timestamp
        });
      }

    } catch (error) {
      console.error('Error sending message:', error);
      socket.emit('error', { message: 'Failed to send message' });
    }
  });

  // Edit message
  socket.on('edit-message', async (data) => {
    try {
      const user = onlineUsers.get(socket.id);
      if (!user) return;

      const message = await messagesCollection.findOne({ 
        _id: new ObjectId(data.messageId),
        userId: user.userId
      });

      if (!message) {
        socket.emit('error', { message: 'Cannot edit this message' });
        return;
      }

      await messagesCollection.updateOne(
        { _id: new ObjectId(data.messageId) },
        { 
          $set: { 
            message: data.newMessage,
            edited: true,
            editedAt: new Date()
          } 
        }
      );

      const updatedMessage = {
        messageId: data.messageId,
        newMessage: data.newMessage,
        edited: true,
        editedAt: new Date()
      };

      if (message.isPrivate) {
        const recipientSocketId = userSocketMap.get(message.recipientId);
        if (recipientSocketId) {
          io.to(recipientSocketId).emit('message-edited', updatedMessage);
        }
        socket.emit('message-edited', updatedMessage);
      } else {
        io.to(message.room).emit('message-edited', updatedMessage);
      }

    } catch (error) {
      console.error('Error editing message:', error);
      socket.emit('error', { message: 'Failed to edit message' });
    }
  });

  // Delete message
  socket.on('delete-message', async (data) => {
    try {
      const user = onlineUsers.get(socket.id);
      if (!user) return;

      const message = await messagesCollection.findOne({ 
        _id: new ObjectId(data.messageId),
        userId: user.userId
      });

      if (!message) {
        socket.emit('error', { message: 'Cannot delete this message' });
        return;
      }

      await messagesCollection.deleteOne({ _id: new ObjectId(data.messageId) });

      // Delete associated reactions and read receipts
      await reactionsCollection.deleteMany({ messageId: data.messageId });
      await readReceiptsCollection.deleteMany({ messageId: data.messageId });

      if (message.isPrivate) {
        const recipientSocketId = userSocketMap.get(message.recipientId);
        if (recipientSocketId) {
          io.to(recipientSocketId).emit('message-deleted', { messageId: data.messageId });
        }
        socket.emit('message-deleted', { messageId: data.messageId });
      } else {
        io.to(message.room).emit('message-deleted', { messageId: data.messageId });
      }

    } catch (error) {
      console.error('Error deleting message:', error);
      socket.emit('error', { message: 'Failed to delete message' });
    }
  });

  // Add reaction to message
  socket.on('add-reaction', async (data) => {
    try {
      const user = onlineUsers.get(socket.id);
      if (!user) return;

      const reaction = {
        messageId: data.messageId,
        userId: user.userId,
        userName: user.userName,
        emoji: data.emoji,
        timestamp: new Date()
      };

      // Check if user already reacted with this emoji
      const existing = await reactionsCollection.findOne({
        messageId: data.messageId,
        userId: user.userId,
        emoji: data.emoji
      });

      if (existing) {
        // Remove reaction (toggle)
        await reactionsCollection.deleteOne({ _id: existing._id });
      } else {
        // Add reaction
        await reactionsCollection.insertOne(reaction);
      }

      // Get all reactions for this message
      const reactions = await reactionsCollection
        .find({ messageId: data.messageId })
        .toArray();

      // Get message to know which room
      const message = await messagesCollection.findOne({ 
        _id: new ObjectId(data.messageId) 
      });

      if (message) {
        if (message.isPrivate) {
          const recipientSocketId = userSocketMap.get(message.recipientId);
          if (recipientSocketId) {
            io.to(recipientSocketId).emit('reactions-updated', {
              messageId: data.messageId,
              reactions: reactions
            });
          }
          socket.emit('reactions-updated', {
            messageId: data.messageId,
            reactions: reactions
          });
        } else {
          io.to(message.room).emit('reactions-updated', {
            messageId: data.messageId,
            reactions: reactions
          });
        }
      }

    } catch (error) {
      console.error('Error adding reaction:', error);
    }
  });

  // Mark message as read
  socket.on('mark-read', async (data) => {
    try {
      const user = onlineUsers.get(socket.id);
      if (!user) return;

      const readReceipt = {
        messageId: data.messageId,
        userId: user.userId,
        userName: user.userName,
        readAt: new Date()
      };

      await readReceiptsCollection.updateOne(
        { messageId: data.messageId, userId: user.userId },
        { $set: readReceipt },
        { upsert: true }
      );

      // Notify sender
      const message = await messagesCollection.findOne({ 
        _id: new ObjectId(data.messageId) 
      });

      if (message) {
        const senderSocketId = userSocketMap.get(message.userId);
        if (senderSocketId) {
          io.to(senderSocketId).emit('message-read', {
            messageId: data.messageId,
            readBy: user.userName,
            readAt: readReceipt.readAt
          });
        }
      }

    } catch (error) {
      console.error('Error marking message as read:', error);
    }
  });

  // Get read receipts for a message
  socket.on('get-read-receipts', async (data) => {
    try {
      const receipts = await readReceiptsCollection
        .find({ messageId: data.messageId })
        .toArray();

      socket.emit('read-receipts', {
        messageId: data.messageId,
        receipts: receipts
      });

    } catch (error) {
      console.error('Error getting read receipts:', error);
    }
  });

  // Typing indicator
  socket.on('typing', (data) => {
    const user = onlineUsers.get(socket.id);
    if (user) {
      if (data.isPrivate && data.recipientId) {
        const recipientSocketId = userSocketMap.get(data.recipientId);
        if (recipientSocketId) {
          io.to(recipientSocketId).emit('user-typing', { 
            userName: user.userName,
            userId: user.userId
          });
        }
      } else {
        socket.to(user.room).emit('user-typing', { 
          userName: user.userName,
          userId: user.userId
        });
      }
    }
  });

  socket.on('stop-typing', (data) => {
    const user = onlineUsers.get(socket.id);
    if (user) {
      if (data && data.isPrivate && data.recipientId) {
        const recipientSocketId = userSocketMap.get(data.recipientId);
        if (recipientSocketId) {
          io.to(recipientSocketId).emit('user-stop-typing', { 
            userId: user.userId 
          });
        }
      } else {
        socket.to(user.room).emit('user-stop-typing', { 
          userId: user.userId 
        });
      }
    }
  });

  // Create new chat room
  socket.on('create-room', async (data) => {
    try {
      const user = onlineUsers.get(socket.id);
      if (!user) return;

      const room = {
        name: data.name.toLowerCase().replace(/\s+/g, '-'),
        displayName: data.name,
        description: data.description || '',
        icon: data.icon || '💬',
        createdBy: user.userName,
        createdAt: new Date(),
        members: []
      };

      const result = await chatRoomsCollection.insertOne(room);
      room._id = result.insertedId;

      io.emit('room-created', room);

    } catch (error) {
      console.error('Error creating room:', error);
      socket.emit('error', { message: 'Failed to create room' });
    }
  });

  // Disconnect
  socket.on('disconnect', async () => {
    const user = onlineUsers.get(socket.id);
    if (user) {
      console.log('User disconnected:', user.userName);

      // Update database
      await usersCollection.updateOne(
        { email: user.email },
        { 
          $set: { 
            status: 'offline',
            lastSeen: new Date()
          } 
        }
      );

      userSocketMap.delete(user.userId);
      onlineUsers.delete(socket.id);

      io.emit('user-left', {
        userName: user.userName,
        userId: user.userId,
        onlineCount: onlineUsers.size
      });

      io.emit('online-count', onlineUsers.size);
    }
  });
});

// API Routes
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.get('/register', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'register.html'));
});

app.get('/login', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

app.get('/users', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'users.html'));
});

app.get('/dashboard', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'dashboard.html'));
});

// Health check
app.get('/health', (req, res) => {
  if (db) {
    res.status(200).json({ 
      status: 'healthy', 
      database: 'connected',
      onlineUsers: onlineUsers.size
    });
  } else {
    res.status(503).json({ status: 'unhealthy', database: 'disconnected' });
  }
});

// Register
app.post('/api/register', async (req, res) => {
  try {
    const { name, email, password } = req.body;

    if (!name || !email || !password) {
      return res.status(400).json({
        success: false,
        message: 'All fields are required'
      });
    }

    if (password.length < 6) {
      return res.status(400).json({
        success: false,
        message: 'Password must be at least 6 characters'
      });
    }

    const existingUser = await usersCollection.findOne({ email });
    if (existingUser) {
      return res.status(400).json({
        success: false,
        message: 'Email already registered'
      });
    }

    const hashedPassword = await bcrypt.hash(password, 10);

    const result = await usersCollection.insertOne({
      name,
      email,
      password: hashedPassword,
      status: 'offline',
      createdAt: new Date()
    });

    res.status(201).json({
      success: true,
      message: 'User registered successfully',
      userId: result.insertedId
    });

  } catch (error) {
    console.error('Registration error:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

// Login
app.post('/api/login', async (req, res) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({
        success: false,
        message: 'Email and password are required'
      });
    }

    const user = await usersCollection.findOne({ email });
    if (!user) {
      return res.status(401).json({
        success: false,
        message: 'Invalid email or password'
      });
    }

    const isPasswordValid = await bcrypt.compare(password, user.password);
    if (!isPasswordValid) {
      return res.status(401).json({
        success: false,
        message: 'Invalid email or password'
      });
    }

    await usersCollection.updateOne(
      { _id: user._id },
      { $set: { lastLogin: new Date() } }
    );

    res.status(200).json({
      success: true,
      message: 'Login successful',
      user: {
        id: user._id.toString(),
        name: user.name,
        email: user.email
      }
    });

  } catch (error) {
    console.error('Login error:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

// Get all users
app.get('/api/users', async (req, res) => {
  try {
    if (!db || !usersCollection) {
      return res.status(503).json({
        success: false,
        message: 'Database not connected'
      });
    }

    const users = await usersCollection.find({}, {
      projection: { password: 0 }
    }).toArray();

    res.status(200).json({
      success: true,
      count: users.length,
      users: users
    });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

// Get messages (with search)
app.get('/api/messages', async (req, res) => {
  try {
    const { room, limit, search } = req.query;
    const messageLimit = parseInt(limit) || 50;

    let query = {};
    if (room) query.room = room;
    if (search) {
      query.$text = { $search: search };
    }

    const messages = await messagesCollection
      .find(query)
      .sort({ timestamp: -1 })
      .limit(messageLimit)
      .toArray();

    messages.reverse();

    res.status(200).json({
      success: true,
      count: messages.length,
      messages: messages
    });
  } catch (error) {
    console.error('Error fetching messages:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

// Get private messages between two users
app.get('/api/messages/private/:userId1/:userId2', async (req, res) => {
  try {
    const { userId1, userId2 } = req.params;
    const limit = parseInt(req.query.limit) || 50;

    const messages = await messagesCollection
      .find({
        isPrivate: true,
        $or: [
          { userId: userId1, recipientId: userId2 },
          { userId: userId2, recipientId: userId1 }
        ]
      })
      .sort({ timestamp: -1 })
      .limit(limit)
      .toArray();

    messages.reverse();

    res.status(200).json({
      success: true,
      messages: messages
    });
  } catch (error) {
    console.error('Error fetching private messages:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

// Upload file
app.post('/api/upload', async (req, res) => {
  try {
    if (!req.files || Object.keys(req.files).length === 0) {
      return res.status(400).json({
        success: false,
        message: 'No files uploaded'
      });
    }

    const file = req.files.file;
    const fileName = Date.now() + '-' + file.name;
    const uploadPath = path.join(uploadsDir, fileName);

    await file.mv(uploadPath);

    res.status(200).json({
      success: true,
      fileName: fileName,
      fileUrl: `/uploads/${fileName}`,
      fileType: file.mimetype
    });

  } catch (error) {
    console.error('Error uploading file:', error);
    res.status(500).json({
      success: false,
      message: 'Failed to upload file'
    });
  }
});

// Get chat rooms
app.get('/api/rooms', async (req, res) => {
  try {
    const rooms = await chatRoomsCollection.find({}).toArray();
    res.status(200).json({
      success: true,
      rooms: rooms
    });
  } catch (error) {
    console.error('Error fetching rooms:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

// Get reactions for a message
app.get('/api/reactions/:messageId', async (req, res) => {
  try {
    const reactions = await reactionsCollection
      .find({ messageId: req.params.messageId })
      .toArray();

    res.status(200).json({
      success: true,
      reactions: reactions
    });
  } catch (error) {
    console.error('Error fetching reactions:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`MongoDB: ${mongoUrl.replace(MONGODB_PASSWORD, '****')}`);
  console.log('Socket.IO ready');
});
